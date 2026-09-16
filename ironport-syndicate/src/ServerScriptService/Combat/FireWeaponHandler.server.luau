--!strict
-- Server-authoritative weapon fire. Two exploits fixed from the original scaffold:
--
--  1. Origin spoofing: the original trusted a client-supplied raycast origin
--     wholesale, so an exploiter could fire from anywhere on the map — through
--     walls, across the level, from spectator. Origin is now derived from the
--     player's own HumanoidRootPart, with the client's claimed origin only used
--     as a sanity check against it.
--
--  2. Unlimited fire rate: the original only debounced firing in a client
--     LocalScript, trivially bypassed by calling the remote directly. Fire rate
--     is now enforced here, per player per weapon.
--
-- Also switched from a RemoteFunction to a RemoteEvent: invoking a
-- RemoteFunction yields the client until the server responds, which is added
-- latency for a fast, latency-sensitive action with no real security upside
-- over a validated RemoteEvent.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("WeaponConfig"))
local DamageService = require(script.Parent:WaitForChild("DamageService"))
local PlayerState = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerState"))
local HeatService = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("HeatService"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local fireEvent = remotes:WaitForChild("CombatRemotes"):WaitForChild("FireWeaponRemote") :: RemoteEvent

local ORIGIN_TOLERANCE_STUDS = 8 -- allows for camera offset from the character root

local lastFireTime: { [Player]: { [string]: number } } = {}

local function isRateLimited(player: Player, weaponId: string, fireRateSeconds: number): boolean
	local perPlayer = lastFireTime[player]
	if not perPlayer then
		perPlayer = {}
		lastFireTime[player] = perPlayer
	end

	local now = os.clock()
	local last = perPlayer[weaponId]
	if last and now - last < fireRateSeconds then
		return true
	end

	perPlayer[weaponId] = now
	return false
end

Players.PlayerRemoving:Connect(function(player)
	lastFireTime[player] = nil
end)

fireEvent.OnServerEvent:Connect(function(player: Player, weaponId: string, claimedOrigin: Vector3, direction: Vector3)
	local stats = WeaponConfig[weaponId]
	if not stats then
		return -- unknown weaponId: ignore rather than trust it
	end

	if isRateLimited(player, weaponId, stats.FireRateSeconds) then
		return
	end

	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local state = PlayerState.get(player)

	if not char or not humanoid or not root or not state then
		return
	end
	if state.IsDowned then
		return
	end
	if typeof(claimedOrigin) ~= "Vector3" or typeof(direction) ~= "Vector3" or direction.Magnitude == 0 then
		return
	end

	-- Reject shots whose claimed origin is nowhere near where the server thinks
	-- the player actually is, instead of raycasting from wherever the client says.
	local serverOrigin = root.Position
	if (claimedOrigin - serverOrigin).Magnitude > ORIGIN_TOLERANCE_STUDS then
		return
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { char }

	local result = Workspace:Raycast(serverOrigin, direction.Unit * stats.Range, rayParams)
	if result and result.Instance then
		local hitHumanoid = result.Instance:FindFirstAncestorOfClass("Humanoid")
		if hitHumanoid then
			local isHeadshot = result.Instance.Name == "Head"
			local damage = stats.Damage * (isHeadshot and stats.HeadshotMultiplier or 1)
			DamageService.processDamage(hitHumanoid, damage, player, isHeadshot)
		end
	end

	HeatService.add(player, 2)
end)
