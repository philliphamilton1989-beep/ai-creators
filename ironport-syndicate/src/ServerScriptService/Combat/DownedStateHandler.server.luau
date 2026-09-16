--!strict
-- Owns RevivePlayerRemote and FinishDownedPlayerRemote. Without these the
-- downed state is a countdown to death with no way out, and invoking either
-- remote errors on the client because no OnServerInvoke was ever assigned.
--
-- "Finish" rather than "execute", per the content-safety pass: same mechanic,
-- no execution framing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageService = require(script.Parent:WaitForChild("DamageService"))
local PlayerState = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerState"))
local FactionService = require(script.Parent.Parent:WaitForChild("Factions"):WaitForChild("FactionService"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GameConfig"))

local combatRemotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CombatRemotes")
local reviveRemote = combatRemotes:WaitForChild("RevivePlayerRemote") :: RemoteFunction
local finishRemote = combatRemotes:WaitForChild("FinishDownedPlayerRemote") :: RemoteFunction

local revivesInProgress: { [Player]: true } = {}

local function characterRoot(player: Player): BasePart?
	local character = player.Character
	return character and (character:FindFirstChild("HumanoidRootPart") :: BasePart?)
end

local function distanceBetween(a: Player, b: Player): number?
	local rootA, rootB = characterRoot(a), characterRoot(b)
	if not rootA or not rootB then
		return nil
	end
	return (rootA.Position - rootB.Position).Magnitude
end

-- Shared gate for both actions: the actor has to be alive, on their feet, and
-- standing next to a target who is actually downed.
local function validateInteraction(actor: Player, targetUserId: number, maxRange: number): (Player?, Humanoid?, string?)
	if typeof(targetUserId) ~= "number" then
		return nil, nil, "InvalidTarget"
	end

	local target = Players:GetPlayerByUserId(targetUserId)
	if not target or target == actor then
		return nil, nil, "InvalidTarget"
	end

	local actorState = PlayerState.get(actor)
	if not actorState or actorState.IsDowned then
		return nil, nil, "ActorUnavailable"
	end

	if not DamageService.isDowned(target) then
		return nil, nil, "TargetNotDowned"
	end

	local targetCharacter = target.Character
	local targetHumanoid = targetCharacter and targetCharacter:FindFirstChildOfClass("Humanoid")
	if not targetHumanoid then
		return nil, nil, "TargetUnavailable"
	end

	local distance = distanceBetween(actor, target)
	if not distance or distance > maxRange then
		return nil, nil, "TooFarAway"
	end

	return target, targetHumanoid, nil
end

reviveRemote.OnServerInvoke = function(player: Player, targetUserId: number): (boolean, string)
	local target, targetHumanoid, reason = validateInteraction(player, targetUserId, GameConfig.Bleedout.ReviveRangeStuds)
	if not target or not targetHumanoid then
		return false, reason :: string
	end

	if revivesInProgress[target] then
		return false, "ReviveInProgress"
	end
	revivesInProgress[target] = true

	task.wait(GameConfig.Bleedout.ReviveSeconds)
	revivesInProgress[target] = nil

	-- Re-validate after the channel: the reviver may have walked off, either
	-- player may have been downed or killed, or someone else may have finished
	-- the target while this was running.
	local stillValid, stillHumanoid = validateInteraction(player, targetUserId, GameConfig.Bleedout.ReviveRangeStuds)
	if not stillValid or not stillHumanoid then
		return false, "ReviveInterrupted"
	end

	DamageService.resolveBleedout(stillValid, stillHumanoid, true)
	return true, "Revived"
end

finishRemote.OnServerInvoke = function(player: Player, targetUserId: number): (boolean, string)
	local target, targetHumanoid, reason = validateInteraction(player, targetUserId, GameConfig.Bleedout.FinishRangeStuds)
	if not target or not targetHumanoid then
		return false, reason :: string
	end

	-- Your own crew is off limits: finishing a crewmate is pure griefing, and
	-- the downed player has no recourse against it. Deliberately checked only
	-- here, not in validateInteraction — reviving a crewmate is the whole point
	-- of revive. Two crewless players can still finish each other.
	if FactionService.areCrewmates(player, target) then
		return false, "CannotFinishOwnCrew"
	end

	DamageService.resolveBleedout(target, targetHumanoid, false)
	return true, "Finished"
end
