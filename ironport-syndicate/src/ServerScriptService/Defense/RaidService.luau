--!strict
-- Anti-grief safehouse raiding. The original scaffold's DeclareSafehouseRaidRemote
-- had no cooldown, no new-player protection, and no insurance — the classic
-- crime-RP failure mode where an established crew farms new players until they
-- quit. This adds all three.
--
-- Simplification: raids are tracked per defending player rather than per
-- safehouse, since a safehouse isn't yet an owned place in the world. The
-- cooldown and shield logic carries over unchanged once safehouses belong to a
-- crew instead of an individual.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerState = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerState"))
local FactionService = require(script.Parent.Parent:WaitForChild("Factions"):WaitForChild("FactionService"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GameConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local declareRaidRemote = remotes:WaitForChild("DefenseVendorRemotes"):WaitForChild("DeclareSafehouseRaidRemote") :: RemoteFunction

local RaidService = {}

local lastRaidedAt: { [number]: number } = {} -- keyed by defender UserId

local function secondsSinceJoin(player: Player): number
	local state = PlayerState.get(player)
	if not state then
		return 0
	end
	return os.clock() - state.JoinedAt
end

function RaidService.canRaid(attacker: Player, defender: Player): (boolean, string?)
	if attacker == defender then
		return false, "CannotRaidSelf"
	end

	if FactionService.areCrewmates(attacker, defender) then
		return false, "CannotRaidOwnCrew"
	end

	if secondsSinceJoin(defender) < GameConfig.Raid.NewPlayerShieldSeconds then
		return false, "TargetShielded"
	end

	local last = lastRaidedAt[defender.UserId]
	if last and os.clock() - last < GameConfig.Raid.CooldownSeconds then
		return false, "SafehouseOnCooldown"
	end

	return true
end

function RaidService.resolveRaid(attacker: Player, defender: Player): (boolean, string, number)
	local ok, reason = RaidService.canRaid(attacker, defender)
	if not ok then
		return false, reason :: string, 0
	end

	local defenderState = PlayerState.get(defender)
	local attackerState = PlayerState.get(attacker)
	if not defenderState or not attackerState then
		return false, "TargetUnavailable", 0
	end

	lastRaidedAt[defender.UserId] = os.clock()

	-- A raid can never take everything: a fixed fraction of Street Cash is
	-- always insured, so a raid is a setback, never a full wipe.
	local insured = math.floor(defenderState.StreetCash * GameConfig.Raid.InsuredCashFraction)
	local seizable = defenderState.StreetCash - insured

	defenderState.StreetCash = insured
	attackerState.StreetCash += seizable

	PlayerState.pushOwnerView(defender)
	PlayerState.pushOwnerView(attacker)

	return true, "RaidSucceeded", seizable
end

declareRaidRemote.OnServerInvoke = function(attacker: Player, defenderUserId: number): (boolean, string, number)
	if typeof(defenderUserId) ~= "number" then
		return false, "InvalidTarget", 0
	end

	local defender = Players:GetPlayerByUserId(defenderUserId)
	if not defender then
		return false, "TargetOffline", 0
	end

	return RaidService.resolveRaid(attacker, defender)
end

return RaidService
