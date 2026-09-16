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
local VehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("VehicleConfig"))

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

-- A locked vehicle can still be physically sat in by anyone, so authority has
-- to be enforced when the seat is taken, not just in the UI that offers it.
local function guardSeats(model: Model)
	for _, descendant in model:GetDescendants() do
		if not (descendant:IsA("VehicleSeat") or descendant:IsA("Seat")) then
			continue
		end
		local seat = descendant :: VehicleSeat
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local occupant = seat.Occupant
			if not occupant then
				return
			end
			local character = occupant.Parent
			local player = character and Players:GetPlayerFromCharacter(character)
			if not player then
				return
			end
			if not canOperate(player, model) then
				ejectOccupant(seat)
			end
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

	-- Destroying the model out from under a seated player leaves them stuck
	-- with Sit = true and no seat to stand up from.
	ejectAllOccupants(model)

	-- Clients were told when this spawned; they have to be told it's gone.
	pushState(model, "Despawned")
	model:Destroy()
end

local function destroyVehicle(model: Model)
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

	-- Anyone still riding takes the hit, routed through DamageService so it
	-- respects the downed/bleedout state machine instead of killing outright.
	for _, occupant in ejectAllOccupants(model) do
		DamageService.processDamage(occupant, VehicleConfig.DestructionOccupantDamage, nil, false)
	end

	pushState(model, "Destroyed")
	task.delay(VehicleConfig.DespawnAfterDestroyedSeconds, function()
		if model.Parent then
			despawnModel(model)
		end
	end)
end

function VehicleService.applyDamage(model: Model, damage: number, attacker: Player?)
	if model:GetAttribute("VehicleDestroyed") == true then
		return
	end
	local health = model:GetAttribute("VehicleHealth")
	local maxHealth = model:GetAttribute("VehicleMaxHealth")
	if typeof(health) ~= "number" or typeof(maxHealth) ~= "number" then
		return
	end

	local remaining = math.max(0, health - damage)
	model:SetAttribute("VehicleHealth", remaining)

	if remaining <= 0 then
		destroyVehicle(model)
		return
	end

	setDisabled(model, remaining <= maxHealth * VehicleConfig.DisabledHealthFraction)
	pushState(model, "Damaged")
end

--[[ Spawning ]]

local function nearestSpawnPoint(player: Player): BasePart?
	local folder = Workspace:FindFirstChild("VehicleSpawns")
	if not folder then
		warnOnce("spawns", "no Workspace.VehicleSpawns folder found — vehicles can't be spawned until the level provides spawn points")
		return nil
	end

	local root = characterRoot(player)
	local best: BasePart? = nil
	local bestDistance = math.huge
	for _, child in folder:GetChildren() do
		if not child:IsA("BasePart") then
			continue
		end
		if not root then
			return child
		end
		local distance = (child.Position - root.Position).Magnitude
		if distance < bestDistance then
			bestDistance = distance
			best = child
		end
	end
	return best
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

	local spawnPoint = nearestSpawnPoint(player)
	if not spawnPoint then
		return false, "NoSpawnPoint"
	end

	-- One active vehicle per player: spawning replaces whatever they had out,
	-- so the map doesn't fill with abandoned cars.
	local existing = activeVehicles[player]
	if existing and existing.Model.Parent then
		despawnModel(existing.Model)
	end

	local model = prefab:Clone()
	model:SetAttribute("VehicleId", vehicleId)
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("VehicleMaxHealth", stats.MaxHealth)
	model:SetAttribute("VehicleHealth", stats.MaxHealth)
	model:SetAttribute("VehicleDisabled", false)
	model:SetAttribute("VehicleDestroyed", false)
	model:SetAttribute("VehicleLocked", true)

	model:PivotTo(spawnPoint.CFrame + Vector3.new(0, spawnPoint.Size.Y / 2 + 3, 0))
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

return VehicleService
