--!strict
-- Explosions: one place that knows what a blast does to everything it touches.
--
-- This used to live in VehicleDamageService as applyBlast, which only ever
-- looked for vehicles — a rocket would wreck a van and leave the crew standing
-- beside it untouched. Explosions care about people, vehicles and turrets alike,
-- so the logic moved here rather than being duplicated three ways.
--
-- Falloff is linear from the epicentre to the radius. A direct hit is the full
-- number; standing at the edge is a scratch. Flat damage inside a radius makes a
-- rocket a 15-stud instant-kill disc, which removes any reason to position.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local core = script.Parent.Parent:WaitForChild("Core")
local SafeZoneService = require(core:WaitForChild("SafeZoneService"))
local DamageService = require(script.Parent:WaitForChild("DamageService"))
local VehicleDamageService = require(script.Parent.Parent:WaitForChild("Vehicles"):WaitForChild("VehicleDamageService"))
local VehicleService = require(script.Parent.Parent:WaitForChild("Vehicles"):WaitForChild("VehicleService"))
local TurretService = require(script.Parent.Parent:WaitForChild("Defense"):WaitForChild("TurretService"))

local BlastService = {}

-- 1 at the centre, 0 at the radius.
local function falloff(distance: number, radius: number): number
	if radius <= 0 then
		return 0
	end
	return math.clamp(1 - distance / radius, 0, 1)
end

local function damagePlayers(origin: Vector3, rawDamage: number, radius: number, damageType: string, attacker: Player?)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not character or not root or not humanoid or humanoid.Health <= 0 then
			continue
		end

		-- An explosion is no more allowed into a safe zone than a bullet is.
		if SafeZoneService.isProtected(character) then
			continue
		end

		local distance = (root.Position - origin).Magnitude
		local scale = falloff(distance, radius)
		if scale <= 0 then
			continue
		end

		-- Passed with the real damage type so armored cover cannot absorb it:
		-- cover is a ballistic property, and explosives are what defeats it.
		DamageService.processDamage(humanoid, rawDamage * scale, attacker, false, damageType)
	end
end

local function damageStructures(
	origin: Vector3,
	rawDamage: number,
	radius: number,
	damageType: string,
	attacker: Player?,
	directHit: Model?
)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if directHit then { directHit } else {}

	local seenVehicles: { [Model]: boolean } = {}
	local seenTurrets: { [Model]: boolean } = {}

	for _, part in Workspace:GetPartBoundsInRadius(origin, radius, params) do
		local distance = (part.Position - origin).Magnitude
		local scale = falloff(distance, radius)
		if scale <= 0 then
			continue
		end

		local vehicle = VehicleService.findVehicleFromPart(part)
		if vehicle and not seenVehicles[vehicle] and vehicle ~= directHit then
			seenVehicles[vehicle] = true
			VehicleDamageService.takeDamage(vehicle, rawDamage * scale, damageType, attacker)
			-- Near misses wreck wheels and treads even when the hull holds.
			if vehicle.Parent and vehicle:GetAttribute("VehicleDestroyed") ~= true then
				VehicleDamageService.applyConcussion(vehicle)
			end
			continue
		end

		local turret = TurretService.findTurretFromPart(part)
		if turret and not seenTurrets[turret] then
			seenTurrets[turret] = true
			TurretService.takeDamage(turret, rawDamage * scale, attacker)
		end
	end
end

-- A detonation at a point. `directHit` is what the projectile actually struck,
-- if anything; it takes the full undiminished number and everything else is
-- scaled by distance.
function BlastService.detonate(
	origin: Vector3,
	rawDamage: number,
	radius: number,
	damageType: string?,
	attacker: Player?,
	directHit: Model?
)
	local resolvedType = damageType or "HeavyExplosive"

	if directHit and directHit.Parent then
		if VehicleService.findVehicleFromPart(directHit.PrimaryPart or directHit:FindFirstChildWhichIsA("BasePart")) then
			VehicleDamageService.takeDamage(directHit, rawDamage, resolvedType, attacker)
		else
			TurretService.takeDamage(directHit, rawDamage, attacker)
		end
	end

	damagePlayers(origin, rawDamage, radius, resolvedType, attacker)
	damageStructures(origin, rawDamage, radius, resolvedType, attacker, directHit)
end

return BlastService
