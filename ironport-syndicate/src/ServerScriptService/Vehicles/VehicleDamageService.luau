--!strict
-- All vehicle damage: resistance, health, damage states, destruction trigger.
--
-- Split out of VehicleService so the damage math sits in one place. The division
-- is: this module decides how much a hit is worth and what state that leaves the
-- vehicle in; VehicleService still owns the vehicle's life (spawning, ownership,
-- cargo, the actual destruction), and this calls into it at zero.
--
-- Health is an Attribute on the model, not a ValueObject. Attributes replicate
-- the same way, cost less, and the prefab's own drive script already reads
-- VehicleDisabled and VehicleSpeedMultiplier off the model — the established
-- contract is that this service publishes state and the prefab reacts to it.
--
-- Damage type matters: the same raw number means different things depending on
-- where it came from, and the whole balance of an armored vehicle is in that
-- conversion. Untyped damage is treated as ballistic.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleService = require(script.Parent:WaitForChild("VehicleService"))
local VehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("VehicleConfig"))
local ArmoredVehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ArmoredVehicleConfig"))

local VehicleDamageService = {}

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

-- Returns the damage actually applied after armor, so callers (and tests) can
-- see the conversion rather than inferring it from the health delta.
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

--[[ Damage state effects ]]

local function findEffectAnchor(model: Model): BasePart?
	-- Level design can name a part EngineBlock to place the smoke precisely;
	-- otherwise it goes on whatever the model pivots around.
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

	if model:GetAttribute("VehicleSpeedMultiplier") ~= speed then
		model:SetAttribute("VehicleSpeedMultiplier", speed)
	end
	-- An armored vehicle degrades rather than stalling: it is meant to limp out
	-- of a firefight, not become a stationary coffin at 25%.
	if model:GetAttribute("VehicleDisabled") ~= false then
		model:SetAttribute("VehicleDisabled", false)
	end

	if not anchor then
		return
	end

	setEmitter(anchor, "EngineSmoke", smoke, function()
		local emitter = Instance.new("ParticleEmitter")
		emitter.Rate = 18
		emitter.Lifetime = NumberRange.new(1.2, 2.4)
		emitter.Speed = NumberRange.new(3, 6)
		emitter.SpreadAngle = Vector2.new(25, 25)
		emitter.Size = NumberSequence.new(1.6, 4)
		emitter.Transparency = NumberSequence.new(0.35, 1)
		emitter.Color = ColorSequence.new(Color3.fromRGB(48, 46, 44))
		return emitter
	end)

	setEmitter(anchor, "EngineFire", fire, function()
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
	end)
end

VehicleDamageService.applyDamageState = applyDamageState

--[[ Entry point ]]

-- Server-authoritative. Every damage source routes through here; nothing writes
-- VehicleHealth directly.
function VehicleDamageService.takeDamage(model: Model, rawDamage: number, damageType: string?, attacker: Player?): number
	if typeof(rawDamage) ~= "number" or rawDamage ~= rawDamage or rawDamage <= 0 then
		return 0
	end
	if model:GetAttribute("VehicleDestroyed") == true then
		return 0
	end

	local health = model:GetAttribute("VehicleHealth")
	local maxHealth = model:GetAttribute("VehicleMaxHealth")
	if typeof(health) ~= "number" or typeof(maxHealth) ~= "number" or maxHealth <= 0 then
		return 0
	end

	local applied = VehicleDamageService.resolveDamage(model, rawDamage, damageType)
	local remaining = math.max(0, health - applied)
	model:SetAttribute("VehicleHealth", remaining)

	if remaining <= 0 then
		VehicleService.destroy(model, attacker)
		return applied
	end

	applyDamageState(model, remaining / maxHealth)
	VehicleService.publishState(model, "Damaged")
	return applied
end

return VehicleDamageService
