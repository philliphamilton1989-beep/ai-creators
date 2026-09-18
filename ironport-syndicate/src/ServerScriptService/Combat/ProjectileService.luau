--!strict
-- Server-simulated projectiles.
--
-- The rocket is the counter to armor, and the thing that keeps that counter
-- fair is that it takes time to arrive. 2750 damage that could not miss would
-- make a 285,000 vehicle unbuyable; a rocket you can see coming and drive away
-- from makes the exchange a duel. So the round is simulated rather than
-- raycast, and it can genuinely miss.
--
-- The server owns the position. The part exists in Workspace so clients see it,
-- but nothing about where it is or what it hits comes from a client — a
-- client-authoritative rocket would be a free delete button for any vehicle on
-- the map.
--
-- Stepped in one shared loop rather than a thread per rocket, for the same
-- reason the turrets are: a dozen coroutines racing the scheduler buys nothing
-- over a single pass.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BlastService = require(script.Parent:WaitForChild("BlastService"))
local VehicleService = require(script.Parent.Parent:WaitForChild("Vehicles"):WaitForChild("VehicleService"))
local TurretService = require(script.Parent.Parent:WaitForChild("Defense"):WaitForChild("TurretService"))

local ProjectileService = {}

type Projectile = {
	Part: BasePart,
	Position: Vector3,
	Direction: Vector3,
	Speed: number,
	Damage: number,
	BlastRadius: number,
	DamageType: string,
	Owner: Player,
	DistanceRemaining: number,
}

local active: { Projectile } = {}

local function buildRocket(position: Vector3, direction: Vector3): BasePart
	local part = Instance.new("Part")
	part.Name = "Rocket"
	part.Size = Vector3.new(0.6, 0.6, 2.4)
	part.Color = Color3.fromRGB(58, 54, 48)
	part.Material = Enum.Material.Metal
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false -- must never be hit by its own or anyone else's raycast
	part.CFrame = CFrame.lookAt(position, position + direction)

	local trail = Instance.new("ParticleEmitter")
	trail.Rate = 40
	trail.Lifetime = NumberRange.new(0.3, 0.6)
	trail.Speed = NumberRange.new(0, 1)
	trail.Size = NumberSequence.new(0.9, 2.2)
	trail.Transparency = NumberSequence.new(0.2, 1)
	trail.Color = ColorSequence.new(Color3.fromRGB(120, 116, 110))
	trail.Parent = part

	part.Parent = Workspace
	return part
end

local function detonate(projectile: Projectile, position: Vector3, hitInstance: BasePart?)
	local directHit: Model? = nil
	if hitInstance then
		directHit = VehicleService.findVehicleFromPart(hitInstance) or TurretService.findTurretFromPart(hitInstance)
	end

	BlastService.detonate(
		position,
		projectile.Damage,
		projectile.BlastRadius,
		projectile.DamageType,
		projectile.Owner,
		directHit
	)

	if projectile.Part.Parent then
		projectile.Part:Destroy()
	end
end

-- Launches a round. Origin and direction come from the server's own view of the
-- shooter (see FireWeaponHandler); nothing here is taken on trust.
function ProjectileService.launch(
	owner: Player,
	origin: Vector3,
	direction: Vector3,
	damage: number,
	speed: number,
	blastRadius: number,
	range: number,
	damageType: string
)
	local unit = direction.Unit
	table.insert(active, {
		Part = buildRocket(origin, unit),
		Position = origin,
		Direction = unit,
		Speed = speed,
		Damage = damage,
		BlastRadius = blastRadius,
		DamageType = damageType,
		Owner = owner,
		DistanceRemaining = range,
	})
end

local function step(projectile: Projectile, dt: number): boolean
	local travel = math.min(projectile.Speed * dt, projectile.DistanceRemaining)
	if travel <= 0 then
		detonate(projectile, projectile.Position, nil)
		return false
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- The shooter's own character is excluded: a rocket that detonated on the
	-- barrel would make the weapon a suicide button.
	params.FilterDescendantsInstances = { projectile.Part, projectile.Owner.Character :: Instance }

	-- Raycast the whole step rather than teleporting and testing. At 90 studs a
	-- second a frame is several studs, which is enough to tunnel clean through a
	-- vehicle and out the far side.
	local result = Workspace:Raycast(projectile.Position, projectile.Direction * travel, params)
	if result then
		detonate(projectile, result.Position, result.Instance)
		return false
	end

	projectile.Position += projectile.Direction * travel
	projectile.DistanceRemaining -= travel
	projectile.Part.CFrame = CFrame.lookAt(projectile.Position, projectile.Position + projectile.Direction)

	if projectile.DistanceRemaining <= 0 then
		detonate(projectile, projectile.Position, nil)
		return false
	end
	return true
end

RunService.Heartbeat:Connect(function(dt)
	for index = #active, 1, -1 do
		local projectile = active[index]
		local alive = false

		local ok, err = pcall(function()
			alive = step(projectile, dt)
		end)
		if not ok then
			warn("ProjectileService: step failed: " .. tostring(err))
			if projectile.Part.Parent then
				projectile.Part:Destroy()
			end
		end

		if not alive or not ok then
			table.remove(active, index)
		end
	end
end)

return ProjectileService
