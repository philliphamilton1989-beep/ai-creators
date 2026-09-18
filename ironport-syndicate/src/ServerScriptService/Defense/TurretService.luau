--!strict
-- Automated turrets: target acquisition, firing, ammo, and being shot back at.
--
-- A turret is any Model under Workspace.Turrets with a TurretTier attribute
-- naming a tier in TurretConfig. Ownership is optional and decides who it
-- shoots:
--
--   OwnerUserId  — a player's turret. Ignores them and their crew.
--   OwnerCrewId  — a crew's turret. Ignores that crew.
--   neither      — a world defense, hostile to everyone. This is what guards
--                  the Zone 3 vaults and boss hideouts, and it means turrets
--                  are useful before player-placed safehouses exist at all.
--
-- All of it is server-side. Turrets do not trust, or even talk to, clients.
--
-- One shared scan loop rather than a thread per turret: a hundred turrets each
-- with their own loop is a hundred schedulers competing, and the work here is
-- trivially batchable.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = script.Parent.Parent:WaitForChild("Core")
local PlayerState = require(core:WaitForChild("PlayerState"))
local SafeZoneService = require(core:WaitForChild("SafeZoneService"))
local DamageService = require(script.Parent.Parent:WaitForChild("Combat"):WaitForChild("DamageService"))
local VehicleDamageService = require(script.Parent.Parent:WaitForChild("Vehicles"):WaitForChild("VehicleDamageService"))
local VehicleService = require(script.Parent.Parent:WaitForChild("Vehicles"):WaitForChild("VehicleService"))
local FactionService = require(script.Parent.Parent:WaitForChild("Factions"):WaitForChild("FactionService"))
local InventoryService = require(script.Parent.Parent:WaitForChild("Inventory"):WaitForChild("InventoryService"))
local TurretConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("TurretConfig"))

local TurretService = {}

type TurretState = {
	Model: Model,
	Anchor: BasePart,
	TierName: string,
	RoundsInMagazine: number,
	ReserveMagazines: number,
	NextFireAt: number,
	ReloadingUntil: number,
	-- Current target and when it was first acquired, for the warm-up delay.
	Target: Model?,
	AcquiredAt: number,
}

local turrets: { [Model]: TurretState } = {}

local function tierOf(state: TurretState): TurretConfig.TurretTier
	return TurretConfig.Tiers[state.TierName]
end

--[[ Ownership ]]

-- Whether this turret considers the player friendly. A turret with no owner is
-- friendly to nobody, which is what makes world defenses work.
local function isFriendly(state: TurretState, player: Player): boolean
	local ownerUserId = state.Model:GetAttribute("OwnerUserId")
	if typeof(ownerUserId) == "number" then
		if player.UserId == ownerUserId then
			return true
		end
		local owner = Players:GetPlayerByUserId(ownerUserId)
		if owner and FactionService.areCrewmates(owner, player) then
			return true
		end
	end

	local ownerCrewId = state.Model:GetAttribute("OwnerCrewId")
	if typeof(ownerCrewId) == "string" and ownerCrewId ~= "" then
		if FactionService.getCrewIdOf(player) == ownerCrewId then
			return true
		end
	end

	return false
end

--[[ Targeting ]]

local function hasLineOfSight(state: TurretState, targetPart: BasePart): boolean
	local origin = state.Anchor.Position
	local direction = targetPart.Position - origin

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { state.Model }

	local result = Workspace:Raycast(origin, direction, params)
	if not result then
		return true
	end
	-- Clear if the first thing hit belongs to the target itself.
	return result.Instance:IsDescendantOf(targetPart.Parent :: Instance)
end

-- Returns the best target, preferring vehicles. A turret that kept plinking at
-- infantry while an armored vehicle parked on its doorstep would never burn the
-- ammo the raid economy is built around.
local function acquireTarget(state: TurretState): Model?
	local tier = tierOf(state)
	local origin = state.Anchor.Position

	local bestVehicle: Model?, bestVehicleDist = nil, math.huge
	local bestPlayer: Model?, bestPlayerDist = nil, math.huge

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not character or not root or not humanoid or humanoid.Health <= 0 then
			continue
		end
		if isFriendly(state, player) then
			continue
		end

		local playerState = PlayerState.get(player)
		if TurretConfig.IgnoreDownedTargets and playerState and playerState.IsDowned then
			continue
		end
		-- A turret must not reach into a safe zone any more than a player can.
		if SafeZoneService.isProtected(character) then
			continue
		end

		local distance = (root.Position - origin).Magnitude
		if distance > tier.RangeStuds or not hasLineOfSight(state, root) then
			continue
		end

		-- A hostile player sitting in a vehicle makes the VEHICLE the target;
		-- that's the whole point of armor being a bullet sponge.
		local seatPart = humanoid.SeatPart
		local vehicle = seatPart and VehicleService.findVehicleFromPart(seatPart)
		if vehicle and vehicle:GetAttribute("VehicleDestroyed") ~= true then
			if distance < bestVehicleDist then
				bestVehicle, bestVehicleDist = vehicle, distance
			end
		elseif distance < bestPlayerDist then
			bestPlayer, bestPlayerDist = character, distance
		end
	end

	if TurretConfig.PreferVehicleTargets and bestVehicle then
		return bestVehicle
	end
	return bestPlayer or bestVehicle
end

local function targetAnchor(target: Model): BasePart?
	local root = target:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return target.PrimaryPart or target:FindFirstChildWhichIsA("BasePart")
end

--[[ Firing ]]

local function fire(state: TurretState, target: Model)
	local tier = tierOf(state)
	local anchor = targetAnchor(target)
	if not anchor then
		return
	end

	state.RoundsInMagazine -= 1
	state.Model:SetAttribute("RoundsInMagazine", state.RoundsInMagazine)

	local humanoid = target:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- Tagged Ballistic so armored cover and vehicle resistance both apply.
		-- attacker is nil: a turret is not a player, and crediting one would put
		-- someone else's name on a kill they did not make.
		DamageService.processDamage(humanoid, tier.Damage, nil, false, "Ballistic")
	else
		VehicleDamageService.takeDamage(target, tier.Damage, "Ballistic", nil)
	end

	if state.RoundsInMagazine <= 0 then
		if state.ReserveMagazines > 0 then
			state.ReserveMagazines -= 1
			state.ReloadingUntil = os.clock() + tier.ReloadSeconds
			state.RoundsInMagazine = tier.MagazineSize
			state.Model:SetAttribute("ReserveMagazines", state.ReserveMagazines)
		else
			-- Dry. Stays offline until someone hauls ammo to it.
			state.RoundsInMagazine = 0
			state.Model:SetAttribute("TurretOffline", true)
		end
		state.Model:SetAttribute("RoundsInMagazine", state.RoundsInMagazine)
	end
end

local function stepTurret(state: TurretState, now: number)
	if state.Model:GetAttribute("TurretDestroyed") == true then
		return
	end
	if state.RoundsInMagazine <= 0 and state.ReserveMagazines <= 0 then
		return -- dry
	end
	if now < state.ReloadingUntil then
		return
	end

	local tier = tierOf(state)
	local target = state.Target

	-- Re-acquire when the current target is gone, dead, or out of range.
	local anchor = target and targetAnchor(target)
	local stillValid = target ~= nil
		and target.Parent ~= nil
		and anchor ~= nil
		and (anchor.Position - state.Anchor.Position).Magnitude <= tier.RangeStuds

	if not stillValid then
		target = acquireTarget(state)
		state.Target = target
		state.AcquiredAt = now
		state.Model:SetAttribute("HasTarget", target ~= nil)
		if not target then
			return
		end
	end

	-- Warm-up: the window that lets a player sprint an exposed gap and live.
	if now - state.AcquiredAt < tier.AcquisitionSeconds then
		return
	end
	if now < state.NextFireAt then
		return
	end

	state.NextFireAt = now + tier.FireRateSeconds
	fire(state, target :: Model)
end

--[[ Damage to turrets ]]

function TurretService.findTurretFromPart(part: BasePart): Model?
	local current: Instance? = part
	while current and current ~= Workspace do
		if current:IsA("Model") and turrets[current :: Model] then
			return current :: Model
		end
		current = current.Parent
	end
	return nil
end

function TurretService.takeDamage(model: Model, damage: number, attacker: Player?): number
	local state = turrets[model]
	if not state or model:GetAttribute("TurretDestroyed") == true then
		return 0
	end

	local health = model:GetAttribute("TurretHealth")
	if typeof(health) ~= "number" then
		return 0
	end

	local remaining = math.max(0, health - damage)
	model:SetAttribute("TurretHealth", remaining)

	if remaining <= 0 then
		model:SetAttribute("TurretDestroyed", true)
		model:SetAttribute("HasTarget", false)
		state.Target = nil
	end
	return damage
end

--[[ Restocking ]]

-- Feeding a turret costs AmmoBoxes out of a player's inventory, which puts
-- defense on the same carry-weight economy as everything else: holding a turret
-- line means hauling 15 lb a magazine to it.
function TurretService.restock(player: Player, model: Model): (boolean, string)
	local state = turrets[model]
	if not state then
		return false, "NotATurret"
	end
	if model:GetAttribute("TurretDestroyed") == true then
		return false, "TurretDestroyed"
	end
	if not isFriendly(state, player) then
		return false, "NotYourTurret"
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or (root.Position - state.Anchor.Position).Magnitude > TurretConfig.RestockRangeStuds then
		return false, "TooFarAway"
	end

	local tier = tierOf(state)
	if state.ReserveMagazines >= tier.ReserveMagazines and state.RoundsInMagazine >= tier.MagazineSize then
		return false, "AlreadyFull"
	end

	if not InventoryService.removeItem(player, "AmmoBox", TurretConfig.RoundsPerAmmoBox) then
		return false, "NoAmmoBox"
	end

	if state.RoundsInMagazine <= 0 then
		state.RoundsInMagazine = tier.MagazineSize
		model:SetAttribute("TurretOffline", false)
	else
		state.ReserveMagazines = math.min(tier.ReserveMagazines, state.ReserveMagazines + 1)
	end

	model:SetAttribute("RoundsInMagazine", state.RoundsInMagazine)
	model:SetAttribute("ReserveMagazines", state.ReserveMagazines)
	return true, "Restocked"
end

--[[ Registration ]]

local function registerTurret(instance: Instance)
	if not instance:IsA("Model") or turrets[instance] then
		return
	end

	local tierName = instance:GetAttribute("TurretTier")
	if typeof(tierName) ~= "string" then
		warn(("TurretService: %s has no TurretTier attribute; skipping"):format(instance:GetFullName()))
		return
	end
	local tier = TurretConfig.Tiers[tierName]
	if not tier then
		warn(("TurretService: %s names unknown tier %q"):format(instance:GetFullName(), tierName))
		return
	end

	local anchor = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart")
	if not anchor then
		warn(("TurretService: %s has no BasePart to fire from"):format(instance:GetFullName()))
		return
	end

	local state: TurretState = {
		Model = instance,
		Anchor = anchor,
		TierName = tierName,
		RoundsInMagazine = tier.MagazineSize,
		ReserveMagazines = tier.ReserveMagazines,
		NextFireAt = 0,
		ReloadingUntil = 0,
		Target = nil,
		AcquiredAt = 0,
	}
	turrets[instance] = state

	instance:SetAttribute("TurretHealth", tier.Health)
	instance:SetAttribute("TurretMaxHealth", tier.Health)
	instance:SetAttribute("TurretDestroyed", false)
	instance:SetAttribute("TurretOffline", false)
	instance:SetAttribute("RoundsInMagazine", state.RoundsInMagazine)
	instance:SetAttribute("ReserveMagazines", state.ReserveMagazines)
	instance:SetAttribute("HasTarget", false)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Restock"
	prompt.ObjectText = tier.DisplayName
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = TurretConfig.RestockRangeStuds
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor
	prompt.Triggered:Connect(function(player: Player)
		TurretService.restock(player, instance)
	end)
end

local function bindFolder(folder: Instance)
	for _, child in folder:GetChildren() do
		registerTurret(child)
	end
	folder.ChildAdded:Connect(registerTurret)
	folder.ChildRemoved:Connect(function(child)
		turrets[child :: Model] = nil
	end)
end

--[[ Loop ]]

local accumulated = 0
RunService.Heartbeat:Connect(function(dt)
	accumulated += dt
	if accumulated < 0.1 then
		return
	end
	accumulated = 0

	local now = os.clock()
	for _, state in turrets do
		if state.Model.Parent then
			stepTurret(state, now)
		end
	end
end)

local folder = Workspace:FindFirstChild("Turrets")
if folder then
	bindFolder(folder)
else
	warn("TurretService: no Workspace.Turrets folder — nothing is defended until the level provides one")
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "Turrets" then
			bindFolder(child)
		end
	end)
end

return TurretService
