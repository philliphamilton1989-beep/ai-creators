--!strict
-- All vehicle damage: classification, resistance, health, damage states,
-- blast handling and the destruction trigger.
--
-- The division of labour is: this module decides what a hit is worth and what
-- state it leaves the vehicle in; VehicleService still owns the vehicle's life
-- (spawning, ownership, cargo, destruction), and this calls into it at zero.
--
-- Damage classification is the spine of the balance:
--
--   Ballistic       0.40  turret and small-arms fire; the thing it tanks
--   Melee           0.25  not a way through armor plate
--   Explosive       1.50  frags and satchels; chips armor
--   HeavyExplosive  2.75  rockets and missiles; the hard counter
--
-- Explosive and HeavyExplosive are separate classes on purpose. A grenade and a
-- missile are not the same event, and one multiplier cannot make a grenade a
-- nuisance while making a missile decisive.
--
-- Speed is layered rather than assigned: a damage-state multiplier from health,
-- times a temporary penalty from blast concussion. A near miss on an already
-- burning vehicle has to compound, not overwrite — assigning a single value
-- would let a late splash hit silently HEAL the speed of a critical vehicle.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local VehicleService = require(script.Parent:WaitForChild("VehicleService"))
local DamageService = require(script.Parent.Parent:WaitForChild("Combat"):WaitForChild("DamageService"))
local SafeZoneService = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("SafeZoneService"))
local VehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("VehicleConfig"))
local ArmoredVehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ArmoredVehicleConfig"))

local VehicleDamageService = {}

-- Per-model temporary speed penalty from blast concussion, and a token so a
-- stale restore can't lift a penalty applied after it.
local speedPenalty: { [Model]: number } = {}
local speedPenaltyToken: { [Model]: number } = {}

local function profileFor(model: Model): ArmoredVehicleConfig.ArmorProfile?
	local vehicleId = model:GetAttribute("VehicleId")
	if typeof(vehicleId) ~= "string" then
		return nil
	end
	local stats = VehicleConfig.Catalog[vehicleId]
	if not stats or not stats.ArmorProfile then
		return nil
	end
	return ArmoredVehicleConfig.Profiles[stats.ArmorProfile]
end

local function isExplosive(damageType: string): boolean
	return ArmoredVehicleConfig.ExplosiveDamageTypes[damageType] == true
end

local function isHeavy(damageType: string): boolean
	return ArmoredVehicleConfig.HeavyDamageTypes[damageType] == true
end

-- Returns the damage actually applied after armor, so callers (and balance
-- checks) can see the conversion rather than inferring it from a health delta.
function VehicleDamageService.resolveDamage(model: Model, rawDamage: number, damageType: string?): number
	local profile = profileFor(model)
	if not profile then
		return rawDamage
	end
	local resolvedType = damageType or ArmoredVehicleConfig.DefaultDamageType
	local multiplier = profile.Multipliers[resolvedType]
	if multiplier == nil then
		multiplier = profile.Multipliers[ArmoredVehicleConfig.DefaultDamageType] or 1
	end
	return rawDamage * multiplier
end

--[[ Speed ]]

local function publishSpeed(model: Model, baseMultiplier: number)
	local penalty = speedPenalty[model] or 1
	local effective = baseMultiplier * penalty
	if model:GetAttribute("VehicleSpeedMultiplier") ~= effective then
		model:SetAttribute("VehicleSpeedMultiplier", effective)
	end
end

local function currentBaseSpeed(model: Model): number
	local base = model:GetAttribute("VehicleBaseSpeedMultiplier")
	return if typeof(base) == "number" then base else 1
end

-- Public so BlastService can apply wheel and tread damage from a near miss
-- without owning the speed-layering rules, which live here.
function VehicleDamageService.applyConcussion(model: Model)
	local blast = ArmoredVehicleConfig.Blast
	VehicleDamageService.applyConcussionPenalty(model, blast.SplashSpeedFraction, blast.SplashSpeedDurationSeconds)
end

function VehicleDamageService.applyConcussionPenalty(model: Model, fraction: number, duration: number)
	speedPenalty[model] = (speedPenalty[model] or 1) * fraction
	publishSpeed(model, currentBaseSpeed(model))

	local token = (speedPenaltyToken[model] or 0) + 1
	speedPenaltyToken[model] = token

	task.delay(duration, function()
		-- Only the most recent penalty may lift the restriction; an earlier
		-- timer firing late must not clear a fresher hit.
		if speedPenaltyToken[model] ~= token or not model.Parent then
			return
		end
		speedPenalty[model] = nil
		publishSpeed(model, currentBaseSpeed(model))
	end)
end

--[[ Damage state effects ]]

local function findEffectAnchor(model: Model): BasePart?
	local named = model:FindFirstChild("EngineBlock")
	if named and named:IsA("BasePart") then
		return named
	end
	return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
end

local function setEmitter(anchor: BasePart, name: string, enabled: boolean, build: () -> ParticleEmitter)
	local existing = anchor:FindFirstChild(name)
	if enabled then
		if not existing then
			local emitter = build()
			emitter.Name = name
			emitter.Parent = anchor
		end
	elseif existing then
		existing:Destroy()
	end
end

local function buildSmoke(): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 18
	emitter.Lifetime = NumberRange.new(1.2, 2.4)
	emitter.Speed = NumberRange.new(3, 6)
	emitter.SpreadAngle = Vector2.new(25, 25)
	emitter.Size = NumberSequence.new(1.6, 4)
	emitter.Transparency = NumberSequence.new(0.35, 1)
	emitter.Color = ColorSequence.new(Color3.fromRGB(48, 46, 44))
	return emitter
end

local function buildFire(): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 26
	emitter.Lifetime = NumberRange.new(0.4, 0.8)
	emitter.Speed = NumberRange.new(5, 9)
	emitter.SpreadAngle = Vector2.new(15, 15)
	emitter.Size = NumberSequence.new(1.2, 0.2)
	emitter.Transparency = NumberSequence.new(0.1, 1)
	emitter.Color = ColorSequence.new(Color3.fromRGB(226, 128, 44), Color3.fromRGB(140, 32, 16))
	emitter.LightEmission = 0.8
	return emitter
end

local function applyDamageState(model: Model, healthFraction: number)
	local profile = profileFor(model)
	local anchor = findEffectAnchor(model)

	if not profile then
		-- Unarmored vehicles keep the original behaviour: below the disabled
		-- fraction the engine is dead, and nothing else changes.
		local disabled = healthFraction <= VehicleConfig.DisabledHealthFraction
		if model:GetAttribute("VehicleDisabled") ~= disabled then
			model:SetAttribute("VehicleDisabled", disabled)
		end
		return
	end

	local smoke, fire, speed = false, false, 1
	for _, state in profile.DamageStates do
		if healthFraction <= state.Threshold then
			smoke, fire, speed = state.Smoke, state.Fire, state.SpeedMultiplier
			break
		end
	end

	-- A critical failure latches: once the engine is gone it does not come back
	-- because health happens to sit in a friendlier band.
	if model:GetAttribute("VehicleCriticalFailure") == true then
		smoke, fire = true, true
		speed = math.min(speed, ArmoredVehicleConfig.CriticalFailure.SpeedMultiplier)
	end

	model:SetAttribute("VehicleBaseSpeedMultiplier", speed)
	publishSpeed(model, speed)

	-- An armored vehicle degrades rather than stalling: it is meant to limp out
	-- of a firefight, not become a stationary coffin at 25%.
	if model:GetAttribute("VehicleDisabled") ~= false then
		model:SetAttribute("VehicleDisabled", false)
	end

	if anchor then
		setEmitter(anchor, "EngineSmoke", smoke, buildSmoke)
		setEmitter(anchor, "EngineFire", fire, buildFire)
	end
end

VehicleDamageService.applyDamageState = applyDamageState

-- One blow big enough to break the vehicle regardless of what health says.
local function checkCriticalFailure(model: Model, appliedDamage: number)
	if appliedDamage < ArmoredVehicleConfig.CriticalFailure.DamageThreshold then
		return
	end
	if model:GetAttribute("VehicleCriticalFailure") == true then
		return
	end
	model:SetAttribute("VehicleCriticalFailure", true)
	if ArmoredVehicleConfig.CriticalFailure.DisableReverse then
		model:SetAttribute("VehicleReverseDisabled", true)
	end
end

--[[ Occupants ]]

local function occupantHumanoids(model: Model): { Humanoid }
	local found = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("VehicleSeat") or descendant:IsA("Seat") then
			local occupant = (descendant :: VehicleSeat).Occupant
			if occupant then
				table.insert(found, occupant)
			end
		end
	end
	return found
end

-- Armor stops bullets, not pressure. A direct explosive hit passes a fraction of
-- the RAW blast to everyone aboard, so riding inside is cover from rifles and
-- only partial cover from ordnance.
local function applyOccupantBleed(model: Model, rawDamage: number, damageType: string, attacker: Player?)
	if not isExplosive(damageType) then
		return
	end
	local profile = profileFor(model)
	if not profile then
		return
	end

	local bleed = rawDamage * ArmoredVehicleConfig.Blast.OccupantBleedFraction
	if bleed <= 0 then
		return
	end

	for _, humanoid in occupantHumanoids(model) do
		-- Passed as explosive so the armored-cover attributes on the character
		-- don't absorb it: cover is a ballistic property.
		DamageService.processDamage(humanoid, bleed, attacker, false, damageType)
	end
end

--[[ Entry points ]]

-- Server-authoritative. Every damage source routes through here; nothing writes
-- VehicleHealth directly.
function VehicleDamageService.takeDamage(model: Model, rawDamage: number, damageType: string?, attacker: Player?): number
	if typeof(rawDamage) ~= "number" or rawDamage ~= rawDamage or rawDamage <= 0 then
		return 0
	end
	if model:GetAttribute("VehicleDestroyed") == true then
		return 0
	end

	-- A loaded van parked outside the pawn shop is the same griefing target as
	-- the player carrying the load, and it has no combat tag of its own, so it's
	-- protected by location alone. A protected attacker can't shoot out either.
	if SafeZoneService.isModelInZone(model) then
		return 0
	end
	if attacker and SafeZoneService.isProtected(attacker.Character) then
		return 0
	end

	local health = model:GetAttribute("VehicleHealth")
	local maxHealth = model:GetAttribute("VehicleMaxHealth")
	if typeof(health) ~= "number" or typeof(maxHealth) ~= "number" or maxHealth <= 0 then
		return 0
	end

	local resolvedType = damageType or ArmoredVehicleConfig.DefaultDamageType
	local applied = VehicleDamageService.resolveDamage(model, rawDamage, resolvedType)
	local remaining = math.max(0, health - applied)

	model:SetAttribute("VehicleHealth", remaining)
	applyOccupantBleed(model, rawDamage, resolvedType, attacker)

	if remaining <= 0 then
		-- Ordnance kills the crew outright instead of ragdolling them clear:
		-- surviving a missile that destroyed the vehicle you were sitting in
		-- would undercut the whole point of ordnance being the hard counter.
		VehicleService.destroy(model, attacker, isHeavy(resolvedType))
		speedPenalty[model] = nil
		speedPenaltyToken[model] = nil
		return applied
	end

	checkCriticalFailure(model, applied)
	applyDamageState(model, remaining / maxHealth)
	VehicleService.publishState(model, "Damaged")
	return applied
end

-- Explosions themselves live in Combat/BlastService. They were here while
-- vehicles were the only thing that could be caught in one, but a blast that
-- only looked for vehicles would wreck a van and leave the crew standing beside
-- it untouched. This module keeps what is genuinely vehicle-specific: the
-- resistance conversion, damage states, and the speed layering that
-- applyConcussion above hands back out.

return VehicleDamageService
