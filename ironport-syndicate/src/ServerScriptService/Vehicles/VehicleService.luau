--!strict
-- Vehicle ownership, spawning, damage and repair.
--
-- Division of labour: this service owns authority (who may drive, how much
-- health is left, whether the engine is dead) and expresses it as attributes on
-- the vehicle model. Each prefab's own drive script owns physics and reads
-- VehicleDisabled to cut throttle. That keeps driving feel in the model where
-- it belongs while every rule that can be cheated stays server-side.
--
-- Vehicle health IS stored as a public attribute, unlike Heat and Street Cash.
-- That's deliberate: a smoking, half-wrecked car is visible to everyone
-- anyway, so there's nothing to leak, and the prefab and client VFX both need
-- to read it.
--
-- Prefabs are expected at ServerStorage.VehicleModels.<vehicleId> and spawn
-- points at Workspace.VehicleSpawns.*. Both are art/level assets that live in
-- the place file rather than in git, so requests fail with a clear reason
-- (rather than erroring) until they exist.

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = script.Parent.Parent:WaitForChild("Core")
local PlayerState = require(core:WaitForChild("PlayerState"))
local DamageService = require(script.Parent.Parent:WaitForChild("Combat"):WaitForChild("DamageService"))
local FactionService = require(script.Parent.Parent:WaitForChild("Factions"):WaitForChild("FactionService"))
local InventoryService = require(script.Parent.Parent:WaitForChild("Inventory"):WaitForChild("InventoryService"))
local VehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("VehicleConfig"))
local ArmoredVehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ArmoredVehicleConfig"))
local InventoryConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("InventoryConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local vehicleRemotes = remotes:WaitForChild("VehicleRemotes")
local purchaseRemote = vehicleRemotes:WaitForChild("PurchaseVehicleRemote") :: RemoteFunction
local spawnRemote = vehicleRemotes:WaitForChild("SpawnVehicleRemote") :: RemoteFunction
local despawnRemote = vehicleRemotes:WaitForChild("DespawnVehicleRemote") :: RemoteFunction
local repairRemote = vehicleRemotes:WaitForChild("RepairVehicleRemote") :: RemoteFunction
local lockRemote = vehicleRemotes:WaitForChild("LockVehicleRemote") :: RemoteFunction
local vehicleStateRemote = vehicleRemotes:WaitForChild("VehicleStateRemote") :: RemoteEvent

type ActiveVehicle = {
	Model: Model,
	VehicleId: string,
	Destroyed: boolean,
}

local VehicleService = {}

local activeVehicles: { [Player]: ActiveVehicle } = {}
-- Declared up here so despawn can clear it; the cargo API itself is at the
-- bottom of the file.
local cargo: { [Model]: { [string]: number } } = {}
local lastSpawnAt: { [Player]: { [string]: number } } = {}
local repairsInProgress: { [Model]: true } = {}
local warnedMissingAssets: { [string]: true } = {}

local function warnOnce(key: string, message: string)
	if warnedMissingAssets[key] then
		return
	end
	warnedMissingAssets[key] = true
	warn("VehicleService: " .. message)
end

local function characterRoot(player: Player): BasePart?
	local char = player.Character
	return char and (char:FindFirstChild("HumanoidRootPart") :: BasePart?)
end

--[[ Lookup ]]

-- Walks up from a hit part to the vehicle model, identified by the VehicleId
-- attribute this service stamps on it at spawn.
function VehicleService.findVehicleFromPart(part: BasePart): Model?
	local current: Instance? = part
	while current and current ~= Workspace do
		if current:IsA("Model") and current:GetAttribute("VehicleId") ~= nil then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function ownerOf(model: Model): Player?
	local userId = model:GetAttribute("OwnerUserId")
	if typeof(userId) ~= "number" then
		return nil
	end
	return Players:GetPlayerByUserId(userId)
end

-- Owner-spawned vehicles are locked to the owner and their crew. Deliberately
-- not open to everyone: carjacking a vehicle someone paid Clean Cash for is a
-- grief vector, and the anti-grief posture in the GDD applies here too.
-- Ambient/world vehicles can ship unlocked (VehicleLocked = false) and remain
-- freely stealable.
local function canOperate(player: Player, model: Model): boolean
	if model:GetAttribute("VehicleLocked") ~= true then
		return true
	end
	local owner = ownerOf(model)
	if not owner then
		return false
	end
	if owner == player then
		return true
	end
	return FactionService.areCrewmates(owner, player)
end

local function isNear(player: Player, model: Model): boolean
	local root = characterRoot(player)
	local pivot = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not root or not pivot then
		return false
	end
	return (root.Position - pivot.Position).Magnitude <= VehicleConfig.InteractRangeStuds
end

local function pushState(model: Model, event: string)
	vehicleStateRemote:FireAllClients({
		Event = event,
		VehicleId = model:GetAttribute("VehicleId"),
		OwnerUserId = model:GetAttribute("OwnerUserId"),
		Health = model:GetAttribute("VehicleHealth"),
		MaxHealth = model:GetAttribute("VehicleMaxHealth"),
		Disabled = model:GetAttribute("VehicleDisabled"),
	})
end

--[[ Seat enforcement ]]

local function ejectOccupant(seat: VehicleSeat | Seat)
	local occupant = seat.Occupant
	if occupant then
		occupant.Sit = false
	end
end

-- Armored cover is published as attributes on the CHARACTER rather than looked
-- up by DamageService. DamageService is required by this module, so it can't
-- require back without a cycle — and a character attribute is something it can
-- already read with no new dependency at all.
local function setOccupantCover(character: Model, model: Model?)
	local profile: ArmoredVehicleConfig.ArmorProfile? = nil
	if model then
		local vehicleId = model:GetAttribute("VehicleId")
		local stats = typeof(vehicleId) == "string" and VehicleConfig.Catalog[vehicleId] or nil
		if stats and stats.ArmorProfile then
			profile = ArmoredVehicleConfig.Profiles[stats.ArmorProfile]
		end
	end

	if not profile then
		character:SetAttribute("CoverBallisticMultiplier", nil)
		character:SetAttribute("CoverPenetrationDamage", nil)
		character:SetAttribute("CoverPenetrationMultiplier", nil)
		return
	end

	character:SetAttribute("CoverBallisticMultiplier", profile.OccupantBallisticMultiplier)
	character:SetAttribute("CoverPenetrationDamage", profile.WindowPenetrationDamage)
	character:SetAttribute("CoverPenetrationMultiplier", profile.WindowPenetrationMultiplier)
end

-- A locked vehicle can still be physically sat in by anyone, so authority has
-- to be enforced when the seat is taken, not just in the UI that offers it.
local function guardSeats(model: Model)
	for _, descendant in model:GetDescendants() do
		if not (descendant:IsA("VehicleSeat") or descendant:IsA("Seat")) then
			continue
		end
		local seat = descendant :: VehicleSeat
		local lastOccupantCharacter: Model? = nil

		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local occupant = seat.Occupant

			if not occupant then
				-- Cover has to be cleared on the character who left, which the
				-- seat no longer points at by the time this fires.
				if lastOccupantCharacter then
					setOccupantCover(lastOccupantCharacter, nil)
					lastOccupantCharacter = nil
				end
				return
			end

			local character = occupant.Parent :: Model?
			local player = character and Players:GetPlayerFromCharacter(character)
			if not character or not player then
				return
			end
			if not canOperate(player, model) then
				ejectOccupant(seat)
				return
			end

			lastOccupantCharacter = character
			setOccupantCover(character, model)
		end)
	end
end

--[[ Damage ]]

local function setDisabled(model: Model, disabled: boolean)
	if model:GetAttribute("VehicleDisabled") ~= disabled then
		model:SetAttribute("VehicleDisabled", disabled)
	end
end

local function ejectAllOccupants(model: Model): { Humanoid }
	local ejected = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("VehicleSeat") or descendant:IsA("Seat") then
			local seat = descendant :: VehicleSeat
			local occupant = seat.Occupant
			if occupant then
				table.insert(ejected, occupant)
				ejectOccupant(seat)
			end
		end
	end
	return ejected
end

local function despawnModel(model: Model)
	local owner = ownerOf(model)
	if owner then
		local active = activeVehicles[owner]
		if active and active.Model == model then
			activeVehicles[owner] = nil
		end
	end
	repairsInProgress[model] = nil
	-- Whatever was loaded goes with it. Cargo is not recoverable from a wreck,
	-- which is the risk that makes hauling a decision.
	cargo[model] = nil

	-- Destroying the model out from under a seated player leaves them stuck
	-- with Sit = true and no seat to stand up from.
	ejectAllOccupants(model)

	-- Clients were told when this spawned; they have to be told it's gone.
	pushState(model, "Despawned")
	model:Destroy()
end

local destructionRng = Random.new()

-- Called by VehicleDamageService when health reaches zero. Exposed rather than
-- local because damage resolution lives there while the vehicle's life is owned
-- here, and only one of those two should be able to end it.
function VehicleService.destroy(model: Model, attacker: Player?)
	if model:GetAttribute("VehicleDestroyed") == true then
		return
	end
	model:SetAttribute("VehicleDestroyed", true)
	model:SetAttribute("VehicleHealth", 0)
	setDisabled(model, true)

	local owner = ownerOf(model)
	if owner then
		local active = activeVehicles[owner]
		if active and active.Model == model then
			active.Destroyed = true
		end
	end

	-- Armored vehicles specify their own blast range; anything else uses the
	-- flat catalog value.
	local minDamage, maxDamage = VehicleConfig.DestructionOccupantDamage, VehicleConfig.DestructionOccupantDamage
	local vehicleId = model:GetAttribute("VehicleId")
	local stats = typeof(vehicleId) == "string" and VehicleConfig.Catalog[vehicleId] or nil
	if stats and stats.ArmorProfile then
		local profile = ArmoredVehicleConfig.Profiles[stats.ArmorProfile]
		if profile then
			minDamage = profile.DestructionOccupantDamageMin
			maxDamage = profile.DestructionOccupantDamageMax
		end
	end

	-- Anyone still riding takes the hit, routed through DamageService so it
	-- respects the downed/bleedout state machine instead of killing outright.
	-- Cover is cleared by the ejection, so the blast is never absorbed by the
	-- armor that just failed.
	for _, occupant in ejectAllOccupants(model) do
		local blast = destructionRng:NextInteger(minDamage, maxDamage)
		DamageService.processDamage(occupant, blast, attacker, false, "Explosive")
	end

	pushState(model, "Destroyed")
	task.delay(VehicleConfig.DespawnAfterDestroyedSeconds, function()
		if model.Parent then
			despawnModel(model)
		end
	end)
end

-- Lets VehicleDamageService publish a state change without reaching into this
-- module's internals.
function VehicleService.publishState(model: Model, event: string)
	pushState(model, event)
end

--[[ Spawning ]]

-- Spawn points nearest-first, rather than just the nearest one: a blocked point
-- should fall through to the next rather than failing the spawn outright.
local function spawnPointsByDistance(player: Player): { BasePart }
	local folder = Workspace:FindFirstChild("VehicleSpawns")
	if not folder then
		warnOnce("spawns", "no Workspace.VehicleSpawns folder found — vehicles can't be spawned until the level provides spawn points")
		return {}
	end

	local points = {}
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(points, child)
		end
	end

	local root = characterRoot(player)
	if root then
		local origin = root.Position
		table.sort(points, function(a, b)
			return (a.Position - origin).Magnitude < (b.Position - origin).Magnitude
		end)
	end
	return points
end

-- True when the volume a vehicle would occupy is clear. Without this a spawn
-- point placed slightly too close to geometry buries the vehicle in a wall,
-- which for an anchored-then-unanchored chassis means either an unusable
-- vehicle or one that is violently ejected by the physics solver.
local function isSpawnClear(point: BasePart, footprint: Vector3, ignore: { Instance }): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.MaxParts = 1

	local padded = footprint + Vector3.one * ArmoredVehicleConfig.SpawnClearancePadding
	local center = point.CFrame * CFrame.new(0, point.Size.Y / 2 + padded.Y / 2, 0)

	local hits = Workspace:GetPartBoundsInBox(center, padded, params)
	for _, hit in hits do
		-- Non-collidable decoration isn't an obstruction.
		if hit.CanCollide then
			return false
		end
	end
	return true
end

-- Bounding size of a prefab, used to test clearance before committing.
local function modelFootprint(prefab: Model): Vector3
	local ok, size = pcall(function()
		local _, boxSize = prefab:GetBoundingBox()
		return boxSize
	end)
	if ok and typeof(size) == "Vector3" then
		return size
	end
	return Vector3.new(8, 6, 16)
end

local function ownsVehicle(player: Player, vehicleId: string): boolean
	local state = PlayerState.get(player)
	return state ~= nil and state.OwnedVehicles[vehicleId] == true
end

--[[ Remote handlers ]]

purchaseRemote.OnServerInvoke = function(player: Player, vehicleId: string): (boolean, string)
	if typeof(vehicleId) ~= "string" then
		return false, "InvalidVehicle"
	end
	local stats = VehicleConfig.Catalog[vehicleId]
	if not stats then
		return false, "UnknownVehicle"
	end
	local state = PlayerState.get(player)
	if not state then
		return false, "PlayerUnavailable"
	end
	if state.OwnedVehicles[vehicleId] then
		return false, "AlreadyOwned"
	end

	if not PlayerState.trySpendCleanCash(player, stats.PurchaseCostCleanCash) then
		return false, "CannotAfford"
	end

	state.OwnedVehicles[vehicleId] = true
	PlayerState.pushInventory(player)

	return true, "Purchased"
end

spawnRemote.OnServerInvoke = function(player: Player, vehicleId: string): (boolean, string)
	if typeof(vehicleId) ~= "string" then
		return false, "InvalidVehicle"
	end
	local stats = VehicleConfig.Catalog[vehicleId]
	if not stats then
		return false, "UnknownVehicle"
	end
	if not ownsVehicle(player, vehicleId) then
		return false, "NotOwned"
	end

	local state = PlayerState.get(player)
	if not state or state.IsDowned then
		return false, "PlayerUnavailable"
	end

	local perPlayer = lastSpawnAt[player]
	if not perPlayer then
		perPlayer = {}
		lastSpawnAt[player] = perPlayer
	end
	local last = perPlayer[vehicleId]
	if last and os.clock() - last < stats.SpawnCooldownSeconds then
		return false, "OnCooldown"
	end

	local modelsFolder = ServerStorage:FindFirstChild("VehicleModels")
	local prefab = modelsFolder and modelsFolder:FindFirstChild(vehicleId)
	if not prefab or not prefab:IsA("Model") then
		warnOnce(
			"prefab_" .. vehicleId,
			("no ServerStorage.VehicleModels.%s model found — add the prefab to the place file"):format(vehicleId)
		)
		return false, "PrefabMissing"
	end

	local points = spawnPointsByDistance(player)
	if #points == 0 then
		return false, "NoSpawnPoint"
	end

	-- One active vehicle per player: spawning replaces whatever they had out,
	-- so the map doesn't fill with abandoned cars. Done before the clearance
	-- test so the outgoing vehicle isn't what blocks the spot.
	local existing = activeVehicles[player]
	if existing and existing.Model.Parent then
		despawnModel(existing.Model)
	end

	local footprint = modelFootprint(prefab)
	local character = player.Character
	local ignore: { Instance } = if character then { character } else {}

	local spawnPoint: BasePart? = nil
	for _, candidate in points do
		if isSpawnClear(candidate, footprint, ignore) then
			spawnPoint = candidate
			break
		end
	end
	if not spawnPoint then
		return false, "AllSpawnPointsBlocked"
	end

	local model = prefab:Clone()
	model:SetAttribute("VehicleId", vehicleId)
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("VehicleMaxHealth", stats.MaxHealth)
	model:SetAttribute("VehicleHealth", stats.MaxHealth)
	model:SetAttribute("VehicleDisabled", false)
	model:SetAttribute("VehicleDestroyed", false)
	model:SetAttribute("VehicleLocked", true)

	model:PivotTo(spawnPoint.CFrame * CFrame.new(0, spawnPoint.Size.Y / 2 + footprint.Y / 2, 0))
	model.Parent = Workspace

	guardSeats(model)
	activeVehicles[player] = { Model = model, VehicleId = vehicleId, Destroyed = false }
	perPlayer[vehicleId] = os.clock()
	pushState(model, "Spawned")

	return true, "Spawned"
end

despawnRemote.OnServerInvoke = function(player: Player): (boolean, string)
	local active = activeVehicles[player]
	if not active or not active.Model.Parent then
		activeVehicles[player] = nil
		return false, "NoActiveVehicle"
	end
	despawnModel(active.Model)
	return true, "Despawned"
end

repairRemote.OnServerInvoke = function(player: Player): (boolean, string)
	local active = activeVehicles[player]
	local model = active and active.Model
	if not model or not model.Parent then
		return false, "NoActiveVehicle"
	end
	if model:GetAttribute("VehicleDestroyed") == true then
		return false, "VehicleDestroyed"
	end
	if repairsInProgress[model] then
		return false, "RepairInProgress"
	end
	if not isNear(player, model) then
		return false, "TooFarFromVehicle"
	end

	local stats = VehicleConfig.Catalog[active.VehicleId]
	local health = model:GetAttribute("VehicleHealth")
	local maxHealth = model:GetAttribute("VehicleMaxHealth")
	if not stats or typeof(health) ~= "number" or typeof(maxHealth) ~= "number" then
		return false, "VehicleUnavailable"
	end

	local missing = maxHealth - health
	if missing <= 0 then
		return false, "AlreadyRepaired"
	end

	local cost = math.ceil(missing * stats.RepairCostPerHealth)
	if not PlayerState.trySpendCleanCash(player, cost) then
		return false, "CannotAfford"
	end

	repairsInProgress[model] = true

	task.delay(stats.RepairSeconds, function()
		repairsInProgress[model] = nil
		-- The vehicle may have been wrecked or despawned mid-repair. The fee is
		-- intentionally not refunded: paying for a repair you then blew up is
		-- the player's risk, not a bug to paper over.
		if not model.Parent or model:GetAttribute("VehicleDestroyed") == true then
			return
		end

		-- Restore only what was paid for, measured from health at completion.
		-- Healing to full here meant starting a 1 HP repair for pocket change,
		-- taking hundreds of damage during the window, and having all of it
		-- repaired for free.
		local currentHealth = model:GetAttribute("VehicleHealth")
		if typeof(currentHealth) ~= "number" then
			return
		end
		model:SetAttribute("VehicleHealth", math.min(maxHealth, currentHealth + missing))

		local restored = model:GetAttribute("VehicleHealth") :: number
		setDisabled(model, restored <= maxHealth * VehicleConfig.DisabledHealthFraction)
		pushState(model, "Repaired")
	end)

	return true, "RepairStarted"
end

lockRemote.OnServerInvoke = function(player: Player, locked: boolean): (boolean, string)
	local active = activeVehicles[player]
	local model = active and active.Model
	if not model or not model.Parent then
		return false, "NoActiveVehicle"
	end
	if ownerOf(model) ~= player then
		return false, "NotOwner"
	end
	model:SetAttribute("VehicleLocked", locked == true)
	pushState(model, "LockChanged")
	return true, if locked == true then "Locked" else "Unlocked"
end

--[[ Lifecycle ]]

-- Grants the free starter vehicle. Called by PlayerJoinHandler once PlayerState
-- exists, for the same ordering reason FactionService.onPlayerReady is.
function VehicleService.onPlayerReady(player: Player)
	local state = PlayerState.get(player)
	if not state then
		return
	end
	local starter = VehicleConfig.StarterVehicleId
	if not state.OwnedVehicles[starter] then
		state.OwnedVehicles[starter] = true
	end
	-- Pushed unconditionally: a returning player who already owns everything
	-- still needs their inventory on arrival, not only when it changes.
	PlayerState.pushInventory(player)
end

Players.PlayerRemoving:Connect(function(player)
	local active = activeVehicles[player]
	if active and active.Model.Parent then
		despawnModel(active.Model)
	end
	activeVehicles[player] = nil
	lastSpawnAt[player] = nil
end)

--[[ Cargo ]]

-- Cargo lives here rather than in InventoryService because this module already
-- owns the vehicle's lifecycle — a wreck or a despawn has to take its contents
-- with it, and that's this file's job to notice.
local cargoRemotes = remotes:WaitForChild("CargoRemotes")
local storeInVehicleRemote = cargoRemotes:WaitForChild("StoreInVehicleRemote") :: RemoteFunction
local takeFromVehicleRemote = cargoRemotes:WaitForChild("TakeFromVehicleRemote") :: RemoteFunction
local cargoStateRemote = cargoRemotes:WaitForChild("VehicleCargoStateRemote") :: RemoteEvent

local function cargoWeight(contents: { [string]: number }): number
	local total = 0
	for itemId, count in contents do
		local definition = InventoryConfig.Items[itemId]
		if definition then
			total += definition.Weight * count
		end
	end
	return total
end

local function pushCargoState(player: Player, model: Model?)
	if not model then
		cargoStateRemote:FireClient(player, { Contents = {}, Weight = 0, Capacity = 0, HasVehicle = false })
		return
	end
	local contents = cargo[model] or {}
	cargoStateRemote:FireClient(player, {
		Contents = contents,
		Weight = cargoWeight(contents),
		Capacity = InventoryConfig.VehicleCargoCapacity,
		HasVehicle = true,
	})
end

-- The vehicle a player may load from or into: their own active one, and only
-- while they're standing next to it.
local function accessibleVehicle(player: Player): Model?
	local active = activeVehicles[player]
	local model = active and active.Model
	if not model or not model.Parent then
		return nil
	end
	if model:GetAttribute("VehicleDestroyed") == true then
		return nil
	end
	if not canOperate(player, model) or not isNear(player, model) then
		return nil
	end
	return model
end

function VehicleService.getCargo(model: Model): { [string]: number }
	return cargo[model] or {}
end

storeInVehicleRemote.OnServerInvoke = function(player: Player, itemId: string, count: number): (boolean, string)
	if typeof(itemId) ~= "string" or typeof(count) ~= "number" then
		return false, "InvalidArgs"
	end
	count = math.floor(count)
	if count <= 0 then
		return false, "InvalidCount"
	end

	local definition = InventoryConfig.Items[itemId]
	if not definition then
		return false, "UnknownItem"
	end

	local model = accessibleVehicle(player)
	if not model then
		return false, "NoVehicleInReach"
	end

	local contents = cargo[model]
	if not contents then
		contents = {}
		cargo[model] = contents
	end

	if cargoWeight(contents) + definition.Weight * count > InventoryConfig.VehicleCargoCapacity then
		return false, "VehicleFull"
	end

	-- Remove from the player first: if that fails they never had it, and nothing
	-- should appear in the vehicle.
	if not InventoryService.removeItem(player, itemId, count) then
		return false, "NotHeld"
	end

	contents[itemId] = (contents[itemId] or 0) + count
	pushCargoState(player, model)
	return true, "Stored"
end

takeFromVehicleRemote.OnServerInvoke = function(player: Player, itemId: string, count: number): (boolean, string)
	if typeof(itemId) ~= "string" or typeof(count) ~= "number" then
		return false, "InvalidArgs"
	end
	count = math.floor(count)
	if count <= 0 then
		return false, "InvalidCount"
	end

	local model = accessibleVehicle(player)
	if not model then
		return false, "NoVehicleInReach"
	end

	local contents = cargo[model]
	local held = contents and contents[itemId] or 0
	if held < count then
		return false, "NotInVehicle"
	end

	-- Add to the player first: tryAddItem enforces their own weight and stack
	-- limits, and a refusal must leave the vehicle's contents untouched.
	local added, reason = InventoryService.tryAddItem(player, itemId, count)
	if not added then
		return false, reason
	end

	local remaining = held - count
	;(contents :: { [string]: number })[itemId] = if remaining > 0 then remaining else nil
	pushCargoState(player, model)
	return true, "Taken"
end

-- Pushed on a timer rather than on proximity events: walking in and out of range
-- is continuous, and this is a cheap way to keep the panel honest without
-- wiring a region check to every vehicle.
task.spawn(function()
	while true do
		task.wait(1)
		for _, player in Players:GetPlayers() do
			pushCargoState(player, accessibleVehicle(player))
		end
	end
end)

return VehicleService
