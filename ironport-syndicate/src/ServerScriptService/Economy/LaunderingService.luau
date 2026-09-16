--!strict
-- Street Cash -> Clean Cash laundering cycle. Street Cash is earned fast and
-- hot but is seizable in a raid; Clean Cash is earned slower but persists and
-- is what upgrades are actually bought with. This is the loop that connects
-- the two.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerState = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerState"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GameConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local launderRemote = remotes:WaitForChild("EconomyRemotes"):WaitForChild("StartLaunderingCycleRemote") :: RemoteFunction

local activeCycles: { [Player]: boolean } = {}

launderRemote.OnServerInvoke = function(player: Player, amount: number): (boolean, string)
	if activeCycles[player] then
		return false, "CycleAlreadyRunning"
	end

	local state = PlayerState.get(player)
	if not state then
		return false, "NoState"
	end
	if typeof(amount) ~= "number" or amount <= 0 or amount > state.StreetCash then
		return false, "InvalidAmount"
	end

	activeCycles[player] = true
	state.StreetCash -= amount
	PlayerState.pushOwnerView(player)

	task.delay(GameConfig.Laundering.CycleSeconds, function()
		activeCycles[player] = nil

		-- Player may have left mid-cycle; the cash they put in is intentionally
		-- not refunded (that's the risk of laundering), but we only pay out if
		-- they're still around to receive it.
		if not player.Parent then
			return
		end

		local leaderstats = player:FindFirstChild("leaderstats")
		local cleanCash = leaderstats and leaderstats:FindFirstChild("Clean Cash") :: IntValue?
		if cleanCash then
			cleanCash.Value += math.floor(amount * GameConfig.Laundering.ConversionRate)
		end
	end)

	return true, "CycleStarted"
end
