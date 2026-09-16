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

-- The cooldown and the shield both live on the defender's persisted PlayerState
-- rather than in a table here. An in-memory cooldown keyed on os.clock was
-- bypassed by any server hop or restart, which defeated the entire anti-farm
-- purpose of this module; and a shield measured from this session's join meant
-- cash-rich veterans were untouchable for the first hour of every session while
-- a genuinely new player's protection never accrued across rejoins.

function RaidService.canRaid(attacker: Player, defender: Player): (boolean, string?)
	if attacker == defender then
		return false, "CannotRaidSelf"
	end

	if FactionService.areCrewmates(attacker, defender) then
		return false, "CannotRaidOwnCrew"
	end

	local defenderState = PlayerState.get(defender)
	if not defenderState then
		return false, "TargetUnavailable"
	end

	if PlayerState.totalPlaytime(defender) < GameConfig.Raid.NewPlayerShieldSeconds then
		return false, "TargetShielded"
	end

	if defenderState.LastRaidedAt > 0 and os.time() - defenderState.LastRaidedAt < GameConfig.Raid.CooldownSeconds then
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

	-- A raid can never take everything: a fixed fraction of Street Cash is
	-- always insured, so a raid is a setback, never a full wipe.
	local insured = math.floor(defenderState.StreetCash * GameConfig.Raid.InsuredCashFraction)
	local seizable = defenderState.StreetCash - insured

	-- Nothing to take means no raid happened, and crucially no cooldown is
	-- stamped. Stamping first let a colluding attacker run a zero-value raid to
	-- hand the defender three hours of immunity.
	if seizable <= 0 then
		return false, "NothingToSeize", 0
	end

	defenderState.LastRaidedAt = os.time()
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
