--!strict
-- Automated turrets: target acquisition, firing, ammo, and being shot back at.
--
-- A turret is any Model under Workspace.Turrets. Ownership is optional and
-- decides who it shoots:
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
local PowerService = require(script.Parent:WaitForChild("PowerService"))
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
	-- Over the area's turret budget, so it sits inert.
	Suppressed: boolean,
	-- The player who has taken manual control via CCTV, if any. Set, the
	-- auto-targeting loop stands down entirely and the gun answers only to
	-- ManualTurretAimRemote / ManualTurretFireRemote from this player.
	OccupiedBy: Player?,
	ManualAimDirection: Vector3?,
}

local turrets: { [Model]: TurretState } = {}

-- Fired when the server ends someone's manual control without them asking —
-- the turret died, they did, they left, or someone else's damage suppressed
-- it. TurretService has no business reaching into ReplicatedStorage for a
-- remote, so it exposes this and lets TurretCCTVHandler do the telling.
local manualControlEndedEvent = Instance.new("BindableEvent")
TurretService.ManualControlEnded = manualControlEndedEvent.Event :: RBXScriptSignal

local function tierOf(state: TurretState): TurretConfig.TurretTier
	return TurretConfig.Tiers[state.TierName]
end

-- Clears manual control without the occupant having asked — the turret died,
-- they did, they left, or the density cap suppressed the gun under them. A
-- no-op if nobody's controlling it, so call sites don't need to check first.
local function forceExitManualControl(state: TurretState, reason: string)
	local occupant = state.OccupiedBy
	if not occupant then
		return
	end
	state.OccupiedBy = nil
	state.ManualAimDirection = nil
	state.Model:SetAttribute("OccupiedByUserId", nil)
	manualControlEndedEvent:Fire(occupant, state.Model, reason)
end

--[[ Density cap ]]

-- Without a cap the winning move is always "add another turret", and a
-- well-funded crew becomes unraidable by arithmetic rather than skill. With one
-- turret tier the cap is a straight count: at most DensityCap guns inside
-- DensityRadiusStuds of each other, and the rest sit inert.
--
-- If a second tier is ever added, this becomes a weighted budget — give the tier
-- a CapCost and sum that instead of adding 1 — and nothing else here changes.
--
-- Turrets over the cap go inert rather than being refused registration: a
-- silently missing turret is far harder to diagnose than a visible dead one.
local function recomputeDensity()
	local ordered: { TurretState } = {}
	for _, state in turrets do
		table.insert(ordered, state)
	end
	-- Stable order so the same turrets stay active across recomputes rather than
	-- flickering as the table's iteration order changes.
	table.sort(ordered, function(a, b)
		return a.Model.Name < b.Model.Name
	end)

	for _, state in ordered do
		local spent = 0
		for _, other in ordered do
			if other == state or other.Suppressed then
				continue
			end
			if (other.Anchor.Position - state.Anchor.Position).Magnitude <= TurretConfig.DensityRadiusStuds then
				spent += 1
			end
		end

		local suppressed = spent + 1 > TurretConfig.DensityCap
		state.Suppressed = suppressed
		state.Model:SetAttribute("TurretSuppressed", suppressed)
		if suppressed then
			-- Sitting in a dead gun with no way to know why is worse than being
			-- dropped out of it; the client gets told and can walk to another one.
			forceExitManualControl(state, "TurretSuppressed")
		end
	end
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

	-- Defenders decide what their guns engage, so a turret covering a driveway
	-- isn't emptying its drum at someone walking past on foot.
	local modeName = state.Model:GetAttribute("TargetMode")
	local mode = TurretConfig.TargetModes[if typeof(modeName) == "string" then modeName else ""]
		or TurretConfig.TargetModes[TurretConfig.DefaultTargetMode]

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
			if mode.Vehicles and distance < bestVehicleDist then
				bestVehicle, bestVehicleDist = vehicle, distance
			end
		elseif mode.Players and distance < bestPlayerDist then
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

-- Shared by the auto-loop and manual fire: spends one round, and starts a
-- reload or goes dry exactly the same way regardless of who pulled the
-- trigger.
local function consumeRound(state: TurretState, tier: TurretConfig.TurretTier)
	state.RoundsInMagazine -= 1
	state.Model:SetAttribute("RoundsInMagazine", state.RoundsInMagazine)

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

local function fire(state: TurretState, target: Model)
	local tier = tierOf(state)
	local anchor = targetAnchor(target)
	if not anchor then
		return
	end

	consumeRound(state, tier)

	local humanoid = target:FindFirstChildOfClass("Humanoid")
	if humanoid then
		-- Tagged Ballistic so armored cover and vehicle resistance both apply.
		-- attacker is nil: a turret is not a player, and crediting one would put
		-- someone else's name on a kill they did not make.
		DamageService.processDamage(humanoid, tier.Damage, nil, false, "Ballistic")
	else
		VehicleDamageService.takeDamage(target, tier.Damage, "Ballistic", nil)
	end
end

local function stepTurret(state: TurretState, now: number)
	if state.Model:GetAttribute("TurretDestroyed") == true then
		return
	end
	if state.Suppressed then
		return -- over the area's turret budget
	end

	if state.OccupiedBy then
		-- A player has this one. The auto-loop stands down entirely — no
		-- acquiring, no firing — and answers to ManualTurretAim/Fire instead.
		local occupant = state.OccupiedBy
		local occCharacter = occupant.Character
		local occHumanoid = occCharacter and occCharacter:FindFirstChildOfClass("Humanoid")
		if not occCharacter or not occHumanoid or occHumanoid.Health <= 0 then
			forceExitManualControl(state, "OccupantDown")
			return
		end

		-- Still drawn from the generator every tick: killing the power darkens
		-- a manually-piloted gun exactly like an automatic one. A raider
		-- pushing the generator disables the finger on the trigger too.
		local tier = tierOf(state)
		local powered = PowerService.requestPower(state.Anchor.Position, tier.PowerDraw)
		if state.Model:GetAttribute("TurretPowered") ~= powered then
			state.Model:SetAttribute("TurretPowered", powered)
		end
		return
	end

	if state.RoundsInMagazine <= 0 and state.ReserveMagazines <= 0 then
		return -- dry
	end
	if now < state.ReloadingUntil then
		return
	end

	local tier = tierOf(state)

	-- No generator in reach, or no fuel in it, and the gun is a statue. This is
	-- the counterplay that makes a raid a tactic rather than a timer: push the
	-- generator and the whole line goes dark at once.
	local powered = PowerService.requestPower(state.Anchor.Position, tier.PowerDraw)
	if state.Model:GetAttribute("TurretPowered") ~= powered then
		state.Model:SetAttribute("TurretPowered", powered)
	end
	if not powered then
		state.Target = nil
		return
	end
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
		forceExitManualControl(state, "TurretDestroyed")
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

--[[ Manual control (CCTV) ]]

-- What RequestCCTVAccessRemote hands back on success: enough for the client
-- to render a HUD without a second round trip.
export type ManualControlInfo = {
	RangeStuds: number,
	FireRateSeconds: number,
	MagazineSize: number,
	RoundsInMagazine: number,
	ReserveMagazines: number,
}

-- Same friendliness and proximity rule as restocking: if you're close enough
-- to feed the gun, you're close enough to climb onto it. No separate access
-- range to invent or keep in sync with the ProximityPrompt's own.
function TurretService.beginManualControl(player: Player, model: Model): (boolean, string, ManualControlInfo?)
	local state = turrets[model]
	if not state then
		return false, "NotATurret", nil
	end
	if model:GetAttribute("TurretDestroyed") == true then
		return false, "TurretDestroyed", nil
	end
	if state.Suppressed then
		return false, "TurretSuppressed", nil
	end
	if not isFriendly(state, player) then
		return false, "NotYourTurret", nil
	end
	if state.OccupiedBy then
		return false, if state.OccupiedBy == player then "AlreadyControlling" else "AlreadyOccupied", nil
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return false, "PlayerUnavailable", nil
	end
	if (root.Position - state.Anchor.Position).Magnitude > TurretConfig.RestockRangeStuds then
		return false, "TooFarAway", nil
	end

	local playerState = PlayerState.get(player)
	if not playerState or playerState.IsDowned then
		return false, "PlayerUnavailable", nil
	end

	-- Taking the wheel drops whatever the auto-loop was tracking; the player's
	-- own aim is what decides the target from here.
	state.OccupiedBy = player
	state.ManualAimDirection = nil
	state.Target = nil
	state.Model:SetAttribute("OccupiedByUserId", player.UserId)
	state.Model:SetAttribute("HasTarget", false)

	local tier = tierOf(state)
	return true,
		"Accessed",
		{
			RangeStuds = tier.RangeStuds,
			FireRateSeconds = tier.FireRateSeconds,
			MagazineSize = tier.MagazineSize,
			RoundsInMagazine = state.RoundsInMagazine,
			ReserveMagazines = state.ReserveMagazines,
		}
end

-- Voluntary exit. Forced exits (destroyed, suppressed, occupant downed or
-- gone) go through forceExitManualControl instead, which also fires the
-- ManualControlEnded signal so the client is told.
function TurretService.endManualControl(player: Player, model: Model)
	local state = turrets[model]
	if not state or state.OccupiedBy ~= player then
		return
	end
	state.OccupiedBy = nil
	state.ManualAimDirection = nil
	state.Model:SetAttribute("OccupiedByUserId", nil)
end

-- Aim is inherently client-authoritative — there's no server truth about
-- where someone is looking — so like FireWeaponHandler's shot direction, it's
-- sanitised, not trusted. The caller (TurretCCTVHandler) does that sanitising;
-- this just refuses anything from a player who isn't the current occupant.
function TurretService.setManualAim(player: Player, model: Model, direction: Vector3): boolean
	local state = turrets[model]
	if not state or state.OccupiedBy ~= player then
		return false
	end
	state.ManualAimDirection = direction.Unit
	return true
end

-- Manual fire raycasts along whatever was last set by setManualAim, rather
-- than trusting a locked-on auto-target — the player is aiming freely, so
-- what's actually downrange is what gets hit, same as a handheld weapon.
function TurretService.manualFire(player: Player, model: Model): (boolean, string)
	local state = turrets[model]
	if not state then
		return false, "NotATurret"
	end
	if state.OccupiedBy ~= player then
		return false, "NotYourTurret"
	end
	if model:GetAttribute("TurretDestroyed") == true then
		return false, "TurretDestroyed"
	end
	if state.Suppressed then
		return false, "TurretSuppressed"
	end
	local direction = state.ManualAimDirection
	if not direction then
		return false, "NotAiming"
	end

	local now = os.clock()
	if now < state.ReloadingUntil then
		return false, "Reloading"
	end
	if state.RoundsInMagazine <= 0 and state.ReserveMagazines <= 0 then
		return false, "OutOfAmmo"
	end
	if now < state.NextFireAt then
		return false, "TooFast"
	end

	local tier = tierOf(state)

	-- Same power gate as the auto-loop: no generator in reach, and the gun
	-- doesn't fire no matter who's aiming it.
	local powered = PowerService.requestPower(state.Anchor.Position, tier.PowerDraw)
	if state.Model:GetAttribute("TurretPowered") ~= powered then
		state.Model:SetAttribute("TurretPowered", powered)
	end
	if not powered then
		return false, "NoPower"
	end

	state.NextFireAt = now + tier.FireRateSeconds
	consumeRound(state, tier)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { state.Model }

	local result = Workspace:Raycast(state.Anchor.Position, direction * tier.RangeStuds, rayParams)
	if not result or not result.Instance then
		return true, "Miss"
	end

	local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
	local hitHumanoid = hitModel and hitModel:FindFirstChildOfClass("Humanoid")
	if hitHumanoid then
		local isHeadshot = result.Instance.Name == "Head"
		-- attacker IS the occupant here, unlike the auto-loop: a person aimed
		-- and pulled the trigger, so the kill is credited to them.
		DamageService.processDamage(hitHumanoid, tier.Damage, player, isHeadshot, "Ballistic")
		return true, "Hit"
	end

	local vehicle = VehicleService.findVehicleFromPart(result.Instance)
	if vehicle then
		VehicleDamageService.takeDamage(vehicle, tier.Damage, "Ballistic", player)
		return true, "Hit"
	end

	local otherTurret = TurretService.findTurretFromPart(result.Instance)
	if otherTurret then
		TurretService.takeDamage(otherTurret, tier.Damage, player)
		return true, "Hit"
	end

	local generator = PowerService.findGeneratorFromPart(result.Instance)
	if generator then
		PowerService.takeDamage(generator, tier.Damage, player)
		return true, "Hit"
	end

	return true, "Miss"
end

--[[ Registration ]]

local function registerTurret(instance: Instance)
	if not instance:IsA("Model") or turrets[instance] then
		return
	end

	-- A missing attribute means the default tier: with one gun in the game,
	-- making every level builder tag every turret by hand buys nothing but a
	-- chance to forget. A tier that IS named and doesn't exist is a typo, and
	-- still refuses to load rather than quietly becoming something else.
	local attribute = instance:GetAttribute("TurretTier")
	local tierName = if typeof(attribute) == "string" then attribute else TurretConfig.DefaultTier
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
		Suppressed = false,
		OccupiedBy = nil,
		ManualAimDirection = nil,
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

	-- Access is a second prompt on a different key so the two don't fight over
	-- the same on-screen slot. Deliberately not connected here: RequestCCTV-
	-- AccessRemote needs to hand the client a reply (starting ammo, range) that
	-- a server-side Triggered listener has nowhere to put, so the client
	-- invokes that remote itself in response to this prompt firing locally.
	local cctvPrompt = Instance.new("ProximityPrompt")
	cctvPrompt.Name = "TurretCCTVPrompt"
	cctvPrompt.ActionText = "Access Camera"
	cctvPrompt.ObjectText = tier.DisplayName
	cctvPrompt.HoldDuration = 0.5
	cctvPrompt.MaxActivationDistance = TurretConfig.RestockRangeStuds
	cctvPrompt.RequiresLineOfSight = false
	cctvPrompt.KeyboardKeyCode = Enum.KeyCode.F
	cctvPrompt.Parent = anchor

	recomputeDensity()
end

local function bindFolder(folder: Instance)
	for _, child in folder:GetChildren() do
		registerTurret(child)
	end
	folder.ChildAdded:Connect(registerTurret)
	folder.ChildRemoved:Connect(function(child)
		local state = turrets[child :: Model]
		if state then
			-- Told before it disappears, or the client is left staring through
			-- a camera that no longer exists.
			forceExitManualControl(state, "TurretRemoved")
		end
		turrets[child :: Model] = nil
		-- A destroyed turret frees its slots, so a suppressed neighbour can wake.
		recomputeDensity()
	end)
end

-- A player who disconnects mid-control leaves their occupancy dangling until
-- the next tick would otherwise notice their character is gone; clearing it
-- immediately means a raidmate can climb into the same gun right away.
Players.PlayerRemoving:Connect(function(player: Player)
	for _, state in turrets do
		if state.OccupiedBy == player then
			forceExitManualControl(state, "PlayerLeft")
		end
	end
end)

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
