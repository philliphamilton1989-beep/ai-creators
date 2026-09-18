--!strict
-- Server-authoritative weapon fire.
--
-- The client supplies only an aim direction. Everything else — which weapon is
-- firing, where the shot starts, how fast it may be fired — comes from server
-- state, because all of it is cheatable otherwise:
--
--  * Origin is the character's own head position. An earlier version accepted a
--    client-sent origin and bounded it with a tolerance, which was both
--    spoofable within the tolerance and mis-tuned (8 studs, against a default
--    third-person camera ~12.5 studs back) so that every shot was rejected.
--    There is no tolerance to get wrong if the origin is never sent.
--  * The weapon is whatever PlayerState says is equipped. A client-supplied
--    weaponId let an exploiter claim Rifle stats with any weapon.
--  * Fire rate is capped per player rather than per weapon, so switching
--    weapons can't be used to multiply the cap.
--
-- Aim direction is inherently client-authoritative — there is no server-side
-- truth about where someone is pointing — so it's sanitised, not trusted.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("WeaponConfig"))
local DamageService = require(script.Parent:WaitForChild("DamageService"))
local PlayerState = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerState"))
local HeatService = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("HeatService"))
local VehicleService = require(script.Parent.Parent:WaitForChild("Vehicles"):WaitForChild("VehicleService"))
local VehicleDamageService = require(script.Parent.Parent:WaitForChild("Vehicles"):WaitForChild("VehicleDamageService"))
local TurretService = require(script.Parent.Parent:WaitForChild("Defense"):WaitForChild("TurretService"))
local PowerService = require(script.Parent.Parent:WaitForChild("Defense"):WaitForChild("PowerService"))
local ProjectileService = require(script.Parent:WaitForChild("ProjectileService"))
local InventoryService = require(script.Parent.Parent:WaitForChild("Inventory"):WaitForChild("InventoryService"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local combatRemotes = remotes:WaitForChild("CombatRemotes")
local fireEvent = combatRemotes:WaitForChild("FireWeaponRemote") :: RemoteEvent
local equipRemote = combatRemotes:WaitForChild("EquipWeaponRemote") :: RemoteFunction

local lastFireTime: { [Player]: number } = {}

local function isFiniteVector(value: Vector3): boolean
	-- NaN fails every comparison with itself, so it slips past a plain
	-- `Magnitude == 0` guard and reaches Workspace:Raycast.
	local magnitude = value.Magnitude
	return magnitude == magnitude and magnitude > 0 and magnitude ~= math.huge
end

local function shotOrigin(character: Model): Vector3?
	local head = character:FindFirstChild("Head") :: BasePart?
	if head then
		return head.Position
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	return root and root.Position
end

equipRemote.OnServerInvoke = function(player: Player, weaponId: string): (boolean, string)
	if typeof(weaponId) ~= "string" or not WeaponConfig[weaponId] then
		return false, "UnknownWeapon"
	end
	local state = PlayerState.get(player)
	if not state then
		return false, "PlayerUnavailable"
	end
	state.EquippedWeaponId = weaponId
	return true, "Equipped"
end

fireEvent.OnServerEvent:Connect(function(player: Player, direction: Vector3)
	if typeof(direction) ~= "Vector3" or not isFiniteVector(direction) then
		return
	end

	local state = PlayerState.get(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not state or not character or not humanoid then
		return
	end
	if state.IsDowned or humanoid.Health <= 0 then
		return
	end

	local stats = WeaponConfig[state.EquippedWeaponId]
	if not stats then
		return
	end

	-- Checked but not committed yet: a shot rejected below must not consume the
	-- player's next legitimate shot.
	local now = os.clock()
	local last = lastFireTime[player]
	if last and now - last < stats.FireRateSeconds then
		return
	end

	local origin = shotOrigin(character)
	if not origin then
		return
	end

	-- Projectile weapons consume a round from inventory and launch a simulated
	-- shot instead of raycasting. The ammo check happens before the cooldown is
	-- committed, so a dry launcher doesn't eat the player's next real shot.
	if stats.Projectile then
		local ammoId = stats.AmmoItemId
		if not ammoId or not InventoryService.removeItem(player, ammoId, 1) then
			return
		end

		lastFireTime[player] = now
		ProjectileService.launch(
			player,
			origin,
			direction.Unit,
			stats.Damage,
			stats.ProjectileSpeed or 90,
			stats.BlastRadius or 15,
			stats.Range,
			stats.DamageType or "HeavyExplosive"
		)
		HeatService.add(player, 8) -- a rocket is louder than a rifle
		return
	end

	lastFireTime[player] = now

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }

	local result = Workspace:Raycast(origin, direction.Unit * stats.Range, rayParams)
	if result and result.Instance then
		-- A Humanoid is a SIBLING of the body parts, both children of the
		-- character Model — never an ancestor of them. Walking the ancestor
		-- chain looking for a Humanoid always returns nil, so look up the Model
		-- and then down to its Humanoid.
		local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
		local hitHumanoid = hitModel and hitModel:FindFirstChildOfClass("Humanoid")

		if hitHumanoid then
			local isHeadshot = result.Instance.Name == "Head"
			local damage = stats.Damage * (isHeadshot and stats.HeadshotMultiplier or 1)
			DamageService.processDamage(hitHumanoid, damage, player, isHeadshot, "Ballistic")
		else
			local vehicle = VehicleService.findVehicleFromPart(result.Instance)
			if vehicle then
				VehicleDamageService.takeDamage(vehicle, stats.Damage, "Ballistic", player)
			else
				-- Turrets are destructible: a defense with no counter is a wall,
				-- and a raid should be a fight rather than a timer.
				local turret = TurretService.findTurretFromPart(result.Instance)
				if turret then
					TurretService.takeDamage(turret, stats.Damage, player)
				else
					-- Killing the power is the whole point of there being power.
					local generator = PowerService.findGeneratorFromPart(result.Instance)
					if generator then
						PowerService.takeDamage(generator, stats.Damage, player)
					end
				end
			end
		end
	end

	HeatService.add(player, 2)
end)

Players.PlayerRemoving:Connect(function(player)
	lastFireTime[player] = nil
end)
