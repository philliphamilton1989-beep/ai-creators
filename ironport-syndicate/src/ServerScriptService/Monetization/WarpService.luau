--!strict
-- Emergency Warp: spends a purchased charge to escape to a safe point.
--
-- Built because the product is sold. A charge that can't be spent is money taken
-- for nothing, so this ships with the product rather than after it — including a
-- fallback destination, so it works before any level content exists.
--
-- The combat lockout is what keeps this from being pay-to-win. An escape route
-- bought in advance is convenience; vanishing mid-firefight while carrying loot
-- someone is actively contesting is buying a fight outcome. Taking fire locks
-- the warp out, so it gets you away from trouble you haven't started rather than
-- out of one you're losing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local core = script.Parent.Parent:WaitForChild("Core")
local PlayerState = require(core:WaitForChild("PlayerState"))
local MonetizationConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MonetizationConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local monetizationRemotes = remotes:WaitForChild("MonetizationRemotes")
local useWarpRemote = monetizationRemotes:WaitForChild("UseWarpRemote") :: RemoteFunction

local WarpService = {}

-- The "recently hit" signal is an attribute DamageService stamps on the
-- character, read here rather than pushed. Same trick as armored cover: it
-- crosses the module boundary without either side requiring the other.

local function warpDestination(): CFrame?
	local folder = Workspace:FindFirstChild("WarpDestinations")
	if folder then
		local candidates = {}
		for _, child in folder:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(candidates, child)
			end
		end
		if #candidates > 0 then
			local chosen = candidates[math.random(1, #candidates)]
			return chosen.CFrame * CFrame.new(0, chosen.Size.Y / 2 + 4, 0)
		end
	end

	-- Fallback so the purchased charge is never unusable: any spawn in the place.
	local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if spawn then
		return spawn.CFrame * CFrame.new(0, spawn.Size.Y / 2 + 4, 0)
	end
	return nil
end

useWarpRemote.OnServerInvoke = function(player: Player): (boolean, string)
	local state = PlayerState.get(player)
	if not state then
		return false, "PlayerUnavailable"
	end
	if state.WarpCharges <= 0 then
		return false, "NoCharges"
	end
	if state.IsDowned then
		return false, "Downed" -- bleeding out is not an escape you can buy
	end

	local character = player.Character
	if not character or not character.PrimaryPart then
		return false, "PlayerUnavailable"
	end

	local lastHit = character:GetAttribute("LastCombatAt")
	if typeof(lastHit) == "number" and os.clock() - lastHit < MonetizationConfig.WarpCombatLockoutSeconds then
		return false, "InCombat"
	end

	local destination = warpDestination()
	if not destination then
		return false, "NoDestination"
	end

	-- Charge is spent only once the move is certain to happen.
	state.WarpCharges -= 1
	PlayerState.pushOwnerView(player)
	character:PivotTo(destination)

	return true, "Warped"
end

return WarpService
