--!strict
-- Owns save/load for persistent player progress. The original scaffold had no
-- DataStore code anywhere, so Clean Cash, Street Cash, Heat and Gang all reset
-- on every rejoin — fatal to retention in a progression-driven game.
--
-- A DataStore outage never blocks play: a failed load falls back to defaults
-- for the session rather than kicking the player, and a failed save is retried
-- with backoff rather than silently dropped.

local DataStoreService = game:GetService("DataStoreService")

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local DataStoreRetry = require(script.Parent:WaitForChild("DataStoreRetry"))

local store = DataStoreService:GetDataStore("IronportSyndicate_PlayerData_v1")

export type SaveData = {
	CleanCash: number,
	StreetCash: number,
	Heat: number,
	GangId: string,
	GangRank: string,
	OwnedVehicles: { [string]: boolean },
	Inventory: { [string]: number },
	PlaytimeSeconds: number,
	LastRaidedAt: number,
}

local Persistence = {}

function Persistence.load(player: Player): SaveData?
	local key = "Player_" .. player.UserId
	local ok, data = DataStoreRetry.run("LoadPlayer " .. player.Name, function()
		return store:GetAsync(key)
	end)
	if not ok then
		warn(("Could not load data for %s — starting fresh this session"):format(player.Name))
		return nil
	end
	return data :: SaveData?
end

function Persistence.save(player: Player)
	local state = PlayerState.get(player)
	if not state then
		return -- never initialised, or already released; nothing to write
	end

	local key = "Player_" .. player.UserId
	local payload: SaveData = {
		-- Read straight off state. This used to come out of the leaderstats
		-- Instance, so a missing Instance skipped the entire save — losing
		-- playtime, the raid cooldown and owned vehicles along with the balance.
		CleanCash = state.CleanCash,
		StreetCash = state.StreetCash,
		Heat = state.Heat,
		GangId = state.GangId,
		GangRank = state.GangRank,
		OwnedVehicles = state.OwnedVehicles,
		Inventory = state.Inventory,
		-- Both drive anti-grief protections, so they have to survive a rejoin
		-- or the protections can be reset at will.
		PlaytimeSeconds = PlayerState.totalPlaytime(player),
		LastRaidedAt = state.LastRaidedAt,
	}

	DataStoreRetry.run("SavePlayer " .. player.Name, function()
		store:SetAsync(key, payload)
	end)
end

return Persistence
