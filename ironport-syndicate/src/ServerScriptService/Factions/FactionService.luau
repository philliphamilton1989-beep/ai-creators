--!strict
-- Crews: creation, invites, roster, ranks and the shared treasury.
--
-- Crew membership is GLOBAL, not per-server: a crew's roster and treasury live
-- in their own DataStore so they survive restarts and are the same crew in
-- every running server. That forces two rules on this module:
--
--  * Structural changes (create / join / leave / kick) go straight to
--    UpdateAsync, because they must be durable and correct immediately.
--  * Cash and contribution accrual is applied to the in-memory copy at once
--    (so players see it instantly) and flushed as an additive delta on a
--    timer. Using UpdateAsync with deltas means two servers crediting the
--    same crew add up instead of overwriting each other.
--
-- Known limit: a roster read can be up to one flush interval stale relative to
-- another server. Membership changes are immediate; treasury totals lag.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")

local core = script.Parent.Parent:WaitForChild("Core")
local PlayerState = require(core:WaitForChild("PlayerState"))
local DataStoreRetry = require(core:WaitForChild("DataStoreRetry"))
local FactionConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("FactionConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local factionRemotes = remotes:WaitForChild("FactionRemotes")
local createCrewRemote = factionRemotes:WaitForChild("CreateCrewRemote") :: RemoteFunction
local inviteRemote = factionRemotes:WaitForChild("InviteToCrewRemote") :: RemoteFunction
local respondToInviteRemote = factionRemotes:WaitForChild("RespondToInviteRemote") :: RemoteFunction
local leaveCrewRemote = factionRemotes:WaitForChild("LeaveCrewRemote") :: RemoteFunction
local kickMemberRemote = factionRemotes:WaitForChild("KickFromCrewRemote") :: RemoteFunction
local donateRemote = factionRemotes:WaitForChild("DonateToCrewRemote") :: RemoteFunction
local crewUpdateRemote = factionRemotes:WaitForChild("CrewUpdateRemote") :: RemoteEvent
local crewInviteRemote = factionRemotes:WaitForChild("CrewInviteRemote") :: RemoteEvent

local crewStore = DataStoreService:GetDataStore("IronportSyndicate_Crews_v1")

local NEUTRAL = "Neutral"
local BOSS_RANK = "Boss"
local FLUSH_INTERVAL_SECONDS = 60

-- Members are keyed by tostring(userId): DataStore serialises to JSON, where
-- number keys are not safe to round-trip.
type MemberRecord = {
	Rank: string,
	Contribution: number,
	DisplayName: string,
}

type Crew = {
	Id: string,
	Name: string,
	OwnerUserId: number,
	Members: { [string]: MemberRecord },
	Treasury: number,
}

type PendingDelta = {
	Treasury: number,
	Contribution: { [string]: number },
}

local FactionService = {}

local crews: { [string]: Crew } = {}
local pendingDeltas: { [string]: PendingDelta } = {}
local pendingInvites: { [Player]: { CrewId: string, FromName: string, ExpiresAt: number } } = {}

local function crewKey(crewId: string): string
	return "Crew_" .. crewId
end

local function rankIndex(rank: string): number
	if rank == BOSS_RANK then
		return #FactionConfig.RankLadder + 1
	end
	for index, rung in FactionConfig.RankLadder do
		if rung.Rank == rank then
			return index
		end
	end
	return 1
end

local function rankForContribution(contribution: number): string
	local earned = FactionConfig.RankLadder[1].Rank
	for _, rung in FactionConfig.RankLadder do
		if contribution >= rung.Contribution then
			earned = rung.Rank
		end
	end
	return earned
end

local function cleanCashValue(player: Player): IntValue?
	local leaderstats = player:FindFirstChild("leaderstats")
	local value = leaderstats and leaderstats:FindFirstChild("Clean Cash")
	return value and (value :: IntValue) or nil
end

local function queueDelta(crewId: string): PendingDelta
	local pending = pendingDeltas[crewId]
	if not pending then
		pending = { Treasury = 0, Contribution = {} }
		pendingDeltas[crewId] = pending
	end
	return pending
end

-- Flushes accrued treasury/contribution for one crew as an additive delta, so
-- concurrent servers combine rather than clobber. A failed flush is re-queued
-- instead of being dropped.
local function flushCrew(crewId: string)
	local pending = pendingDeltas[crewId]
	if not pending then
		return
	end
	pendingDeltas[crewId] = nil

	local ok = DataStoreRetry.run("FlushCrew " .. crewId, function()
		crewStore:UpdateAsync(crewKey(crewId), function(stored: Crew?): Crew?
			if not stored then
				return nil -- crew was disbanded elsewhere; drop the delta
			end
			stored.Treasury += pending.Treasury
			for userIdStr, amount in pending.Contribution do
				local member = stored.Members[userIdStr]
				if member then
					member.Contribution += amount
					member.Rank = if stored.OwnerUserId == tonumber(userIdStr)
						then BOSS_RANK
						else rankForContribution(member.Contribution)
				end
			end
			return stored
		end)
	end)

	if not ok then
		local requeued = queueDelta(crewId)
		requeued.Treasury += pending.Treasury
		for userIdStr, amount in pending.Contribution do
			requeued.Contribution[userIdStr] = (requeued.Contribution[userIdStr] or 0) + amount
		end
	end
end

local function writeCrew(crewId: string, mutator: (Crew?) -> Crew?): (boolean, Crew?)
	flushCrew(crewId) -- keep ordering sane: accrued deltas land before structure changes
	return DataStoreRetry.run("WriteCrew " .. crewId, function()
		return crewStore:UpdateAsync(crewKey(crewId), mutator)
	end)
end

local function loadCrew(crewId: string): Crew?
	local cached = crews[crewId]
	if cached then
		return cached
	end
	local ok, stored = DataStoreRetry.run("LoadCrew " .. crewId, function()
		return crewStore:GetAsync(crewKey(crewId))
	end)
	if not ok or not stored then
		return nil
	end
	local crew = stored :: Crew
	crews[crewId] = crew
	return crew
end

local function onlineMembers(crew: Crew): { Player }
	local online = {}
	for _, player in Players:GetPlayers() do
		if crew.Members[tostring(player.UserId)] then
			table.insert(online, player)
		end
	end
	return online
end

local function rosterPayload(crew: Crew): { [string]: any }
	local roster = {}
	for userIdStr, member in crew.Members do
		table.insert(roster, {
			UserId = tonumber(userIdStr),
			DisplayName = member.DisplayName,
			Rank = member.Rank,
			Contribution = member.Contribution,
		})
	end
	return {
		CrewId = crew.Id,
		Name = crew.Name,
		OwnerUserId = crew.OwnerUserId,
		Treasury = crew.Treasury,
		Roster = roster,
	}
end

local function pushCrewToMembers(crew: Crew)
	local payload = rosterPayload(crew)
	for _, player in onlineMembers(crew) do
		crewUpdateRemote:FireClient(player, payload)
	end
end

local function syncPlayerToCrew(player: Player, crew: Crew?)
	local state = PlayerState.get(player)
	if not state then
		return
	end
	if crew then
		local member = crew.Members[tostring(player.UserId)]
		state.GangId = crew.Id
		state.GangRank = member and member.Rank or FactionConfig.RankLadder[1].Rank
	else
		state.GangId = NEUTRAL
		state.GangRank = FactionConfig.RankLadder[1].Rank
	end
	PlayerState.pushOwnerView(player)
end

-- Runs the crew name through Roblox text filtering before it is ever shown to
-- another player. A filter failure rejects the name rather than falling back to
-- the raw input.
local function filterCrewName(rawName: string, authorUserId: number): string?
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(rawName, authorUserId, Enum.TextFilterContext.PublicChat)
	end)
	if not ok or not result then
		return nil
	end
	local broadcastOk, filtered = pcall(function()
		return (result :: TextFilterResult):GetNonChatStringForBroadcastAsync()
	end)
	if not broadcastOk or typeof(filtered) ~= "string" then
		return nil
	end
	return filtered
end

--[[ Public API ]]

function FactionService.getCrewIdOf(player: Player): string?
	local state = PlayerState.get(player)
	if not state or state.GangId == NEUTRAL then
		return nil
	end
	return state.GangId
end

function FactionService.areCrewmates(a: Player, b: Player): boolean
	local crewA = FactionService.getCrewIdOf(a)
	return crewA ~= nil and crewA == FactionService.getCrewIdOf(b)
end

function FactionService.getCrew(crewId: string): Crew?
	return crews[crewId]
end

-- Called by TerritoryService when held turf pays out. Treasury goes to the
-- crew; contribution credit is split across online members so holding turf
-- advances rank, not just donating cash.
function FactionService.creditTerritoryIncome(crewId: string, cash: number, contributionPool: number)
	-- Queue the treasury delta regardless of whether this server has the crew
	-- cached: turf keeps earning while its holders are in another server, and
	-- the delta is dropped safely if the crew turns out to be disbanded.
	local pending = queueDelta(crewId)
	pending.Treasury += cash

	local crew = crews[crewId]
	if not crew then
		return
	end
	crew.Treasury += cash

	local online = onlineMembers(crew)
	if #online > 0 and contributionPool > 0 then
		local share = math.floor(contributionPool / #online)
		if share > 0 then
			for _, player in online do
				local userIdStr = tostring(player.UserId)
				local member = crew.Members[userIdStr]
				if member then
					member.Contribution += share
					if crew.OwnerUserId ~= player.UserId then
						member.Rank = rankForContribution(member.Contribution)
					end
					pending.Contribution[userIdStr] = (pending.Contribution[userIdStr] or 0) + share
					syncPlayerToCrew(player, crew)
				end
			end
		end
	end

	pushCrewToMembers(crew)
end

function FactionService.onPlayerReady(player: Player)
	local state = PlayerState.get(player)
	if not state or state.GangId == NEUTRAL then
		return
	end

	local crew = loadCrew(state.GangId)
	if not crew or not crew.Members[tostring(player.UserId)] then
		-- Crew disbanded, or they were kicked while offline.
		syncPlayerToCrew(player, nil)
		return
	end

	syncPlayerToCrew(player, crew)
	crewUpdateRemote:FireClient(player, rosterPayload(crew))
end

function FactionService.onPlayerLeaving(player: Player)
	pendingInvites[player] = nil
	local crewId = FactionService.getCrewIdOf(player)
	if crewId then
		flushCrew(crewId)
	end
end

--[[ Remote handlers ]]

createCrewRemote.OnServerInvoke = function(player: Player, rawName: string): (boolean, string)
	if typeof(rawName) ~= "string" then
		return false, "InvalidName"
	end
	local trimmed = rawName:match("^%s*(.-)%s*$") or ""
	if #trimmed < FactionConfig.MinNameLength or #trimmed > FactionConfig.MaxNameLength then
		return false, "NameLength"
	end
	if FactionService.getCrewIdOf(player) then
		return false, "AlreadyInCrew"
	end

	local cash = cleanCashValue(player)
	if not cash then
		return false, "PlayerUnavailable"
	end
	if cash.Value < FactionConfig.CreationCostCleanCash then
		return false, "CannotAfford"
	end

	local filteredName = filterCrewName(trimmed, player.UserId)
	if not filteredName then
		return false, "NameRejected"
	end

	local crewId = HttpService:GenerateGUID(false)
	local crew: Crew = {
		Id = crewId,
		Name = filteredName,
		OwnerUserId = player.UserId,
		Members = {
			[tostring(player.UserId)] = {
				Rank = BOSS_RANK,
				Contribution = 0,
				DisplayName = player.DisplayName,
			},
		},
		Treasury = 0,
	}

	local ok, stored = DataStoreRetry.run("CreateCrew " .. crewId, function()
		return crewStore:UpdateAsync(crewKey(crewId), function(existing: Crew?): Crew
			return existing or crew
		end)
	end)
	if not ok or not stored then
		return false, "SaveFailed" -- nothing charged; they can retry
	end

	local created = stored :: Crew
	cash.Value -= FactionConfig.CreationCostCleanCash
	crews[crewId] = created
	syncPlayerToCrew(player, created)
	crewUpdateRemote:FireClient(player, rosterPayload(created))

	return true, "CrewCreated"
end

inviteRemote.OnServerInvoke = function(player: Player, targetUserId: number): (boolean, string)
	if typeof(targetUserId) ~= "number" then
		return false, "InvalidTarget"
	end

	local crewId = FactionService.getCrewIdOf(player)
	local state = PlayerState.get(player)
	if not crewId or not state then
		return false, "NotInCrew"
	end
	if rankIndex(state.GangRank) < rankIndex(FactionConfig.MinRankToInvite) then
		return false, "RankTooLow"
	end

	local crew = crews[crewId]
	if not crew then
		return false, "CrewUnavailable"
	end

	local memberCount = 0
	for _ in crew.Members do
		memberCount += 1
	end
	if memberCount >= FactionConfig.MaxMembers then
		return false, "CrewFull"
	end

	local target = Players:GetPlayerByUserId(targetUserId)
	if not target then
		return false, "TargetOffline"
	end
	if FactionService.getCrewIdOf(target) then
		return false, "TargetAlreadyInCrew"
	end

	pendingInvites[target] = {
		CrewId = crewId,
		FromName = player.DisplayName,
		ExpiresAt = os.clock() + FactionConfig.InviteExpirySeconds,
	}
	crewInviteRemote:FireClient(target, {
		CrewId = crewId,
		CrewName = crew.Name,
		FromName = player.DisplayName,
		ExpiresInSeconds = FactionConfig.InviteExpirySeconds,
	})

	return true, "InviteSent"
end

respondToInviteRemote.OnServerInvoke = function(player: Player, accept: boolean): (boolean, string)
	local invite = pendingInvites[player]
	if not invite then
		return false, "NoInvite"
	end
	pendingInvites[player] = nil

	if os.clock() > invite.ExpiresAt then
		return false, "InviteExpired"
	end
	if not accept then
		return true, "InviteDeclined"
	end
	if FactionService.getCrewIdOf(player) then
		return false, "AlreadyInCrew"
	end

	local recruitRank = FactionConfig.RankLadder[1].Rank
	local ok, updated = writeCrew(invite.CrewId, function(stored: Crew?): Crew?
		if not stored then
			return nil
		end
		local count = 0
		for _ in stored.Members do
			count += 1
		end
		if count >= FactionConfig.MaxMembers then
			return nil -- abandon the write; crew filled up elsewhere
		end
		stored.Members[tostring(player.UserId)] = {
			Rank = recruitRank,
			Contribution = 0,
			DisplayName = player.DisplayName,
		}
		return stored
	end)

	if not ok or not updated then
		return false, "JoinFailed"
	end

	crews[invite.CrewId] = updated
	syncPlayerToCrew(player, updated)
	pushCrewToMembers(updated)

	return true, "JoinedCrew"
end

leaveCrewRemote.OnServerInvoke = function(player: Player): (boolean, string)
	local crewId = FactionService.getCrewIdOf(player)
	if not crewId then
		return false, "NotInCrew"
	end

	local userIdStr = tostring(player.UserId)
	local ok, updated = writeCrew(crewId, function(stored: Crew?): Crew?
		if not stored then
			return nil
		end
		stored.Members[userIdStr] = nil

		-- The Boss leaving hands the crew to whoever has contributed most,
		-- rather than leaving it locked behind an absent owner.
		if stored.OwnerUserId == player.UserId then
			local successorId: string? = nil
			local best = -1
			for candidateId, member in stored.Members do
				if member.Contribution > best then
					best = member.Contribution
					successorId = candidateId
				end
			end
			if successorId then
				stored.OwnerUserId = tonumber(successorId) :: number
				stored.Members[successorId].Rank = BOSS_RANK
			end
		end

		return stored
	end)

	if not ok then
		return false, "SaveFailed"
	end

	syncPlayerToCrew(player, nil)

	local remaining = 0
	if updated then
		for _ in updated.Members do
			remaining += 1
		end
	end

	if remaining == 0 then
		-- Last one out disbands the crew. This needs RemoveAsync: returning nil
		-- from an UpdateAsync transform cancels the write, it doesn't delete
		-- the key, which would leave an empty crew behind forever.
		crews[crewId] = nil
		pendingDeltas[crewId] = nil
		DataStoreRetry.run("DisbandCrew " .. crewId, function()
			crewStore:RemoveAsync(crewKey(crewId))
		end)
	else
		crews[crewId] = updated :: Crew
		pushCrewToMembers(updated :: Crew)
	end

	return true, "LeftCrew"
end

kickMemberRemote.OnServerInvoke = function(player: Player, targetUserId: number): (boolean, string)
	if typeof(targetUserId) ~= "number" then
		return false, "InvalidTarget"
	end
	if targetUserId == player.UserId then
		return false, "CannotKickSelf"
	end

	local crewId = FactionService.getCrewIdOf(player)
	local state = PlayerState.get(player)
	if not crewId or not state then
		return false, "NotInCrew"
	end
	if rankIndex(state.GangRank) < rankIndex(FactionConfig.MinRankToKick) then
		return false, "RankTooLow"
	end

	local actorRank = rankIndex(state.GangRank)
	local targetIdStr = tostring(targetUserId)
	local ok, updated = writeCrew(crewId, function(stored: Crew?): Crew?
		if not stored then
			return nil
		end
		local target = stored.Members[targetIdStr]
		if not target then
			return nil
		end
		-- Nobody can remove a peer or a superior.
		if rankIndex(target.Rank) >= actorRank then
			return nil
		end
		stored.Members[targetIdStr] = nil
		return stored
	end)

	if not ok or not updated then
		return false, "KickFailed"
	end

	crews[crewId] = updated

	local target = Players:GetPlayerByUserId(targetUserId)
	if target then
		syncPlayerToCrew(target, nil)
		crewUpdateRemote:FireClient(target, { CrewId = nil })
	end
	pushCrewToMembers(updated)

	return true, "MemberKicked"
end

donateRemote.OnServerInvoke = function(player: Player, amount: number): (boolean, string)
	if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return false, "InvalidAmount"
	end
	amount = math.floor(amount)

	local crewId = FactionService.getCrewIdOf(player)
	if not crewId then
		return false, "NotInCrew"
	end
	local crew = crews[crewId]
	if not crew then
		return false, "CrewUnavailable"
	end

	local cash = cleanCashValue(player)
	if not cash or cash.Value < amount then
		return false, "CannotAfford"
	end

	cash.Value -= amount
	crew.Treasury += amount

	local userIdStr = tostring(player.UserId)
	local member = crew.Members[userIdStr]
	if member then
		member.Contribution += amount
		if crew.OwnerUserId ~= player.UserId then
			member.Rank = rankForContribution(member.Contribution)
		end
	end

	local pending = queueDelta(crewId)
	pending.Treasury += amount
	pending.Contribution[userIdStr] = (pending.Contribution[userIdStr] or 0) + amount

	syncPlayerToCrew(player, crew)
	pushCrewToMembers(crew)

	return true, "Donated"
end

--[[ Lifecycle ]]

-- onPlayerReady / onPlayerLeaving are driven explicitly by PlayerJoinHandler so
-- they're ordered against PlayerState's own setup and teardown, rather than
-- racing it from a second PlayerAdded/PlayerRemoving connection.

-- Snapshot the keys first: flushCrew clears its entry and re-adds it on
-- failure, and adding keys mid-traversal is undefined.
local function flushAllPending()
	local crewIds = {}
	for crewId in pendingDeltas do
		table.insert(crewIds, crewId)
	end
	for _, crewId in crewIds do
		flushCrew(crewId)
	end
end

task.spawn(function()
	while true do
		task.wait(FLUSH_INTERVAL_SECONDS)
		flushAllPending()
	end
end)

game:BindToClose(flushAllPending)

return FactionService
