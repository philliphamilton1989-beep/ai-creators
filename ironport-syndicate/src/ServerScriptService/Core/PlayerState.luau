--!strict
-- Server-only private player state (Heat, Street Cash, downed state, etc).
-- Deliberately NOT stored as replicated Attributes on the Player instance:
-- Attributes replicate to every client by default, which would leak Heat and
-- Street Cash to every other player in the server and kill the stealth/heist
-- tension. Updates are pushed only to the owning client, over
-- PlayerStateUpdateRemote:FireClient.
--
-- Clean Cash lives here too, and the leaderstats IntValue is a VIEW of it, not
-- the other way round. It used to be the reverse: every system that spent money
-- reached into leaderstats and mutated the Instance, and Persistence read the
-- balance back out of it at save time — so a missing Instance silently skipped
-- the whole save, including unrelated fields. Spending also went through a
-- read-then-write pair that callers had to keep atomic themselves, which is
-- exactly the shape that produced the crew-creation double-charge.
--
-- So: mutate Clean Cash only through addCleanCash / trySpendCleanCash, never by
-- touching leaderstats. trySpendCleanCash checks and debits with no yield
-- between, which is the property callers actually need.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local coreRemotes = remotes:WaitForChild("CoreRemotes")
local stateUpdateRemote = coreRemotes:WaitForChild("PlayerStateUpdateRemote") :: RemoteEvent
local inventoryUpdateRemote = coreRemotes:WaitForChild("InventoryUpdateRemote") :: RemoteEvent

local GameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GameConfig"))

export type SavedFields = {
	CleanCash: number?,
	StreetCash: number?,
	Heat: number?,
	GangId: string?,
	GangRank: string?,
	OwnedVehicles: { [string]: boolean }?,
	Inventory: { [string]: number }?,
	HasCargoInsurance: boolean?,
	PlaytimeSeconds: number?,
	LastRaidedAt: number?,
}

export type State = {
	CleanCash: number,
	StreetCash: number,
	Heat: number,
	GangId: string,
	GangRank: string,
	OwnedVehicles: { [string]: boolean },
	-- Carried gear, itemId -> count. Weight-limited; see InventoryService.
	Inventory: { [string]: number },
	-- Bought in advance with Clean Cash, consumed by the death it protects.
	HasCargoInsurance: boolean,
	-- Server's record of what the player is holding. Never taken from the
	-- client at fire time: a client-supplied weapon id is a free damage upgrade.
	EquippedWeaponId: string,
	IsDowned: boolean,
	InSafehouse: boolean,
	-- Playtime carried in from previous sessions, and when this one started.
	-- Anti-grief protections key off total playtime rather than time since
	-- joining this server, so they can't be reset by rejoining.
	PlaytimeSeconds: number,
	SessionStartedAt: number,
	-- Wall-clock (os.time) so it stays meaningful across servers and restarts.
	-- os.clock is process uptime and would be bypassed by any server hop.
	LastRaidedAt: number,
}

local PlayerState = {}
local states: { [Player]: State } = {}

-- Mirrors the authoritative balance onto the Roblox leaderboard. Created here so
-- one place guarantees the Instance and the state can't drift apart.
local function syncCleanCashView(player: Player, cleanCash: number)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		local folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
		leaderstats = folder
	end

	local existing = leaderstats:FindFirstChild("Clean Cash")
	if existing and existing:IsA("IntValue") then
		existing.Value = cleanCash
		return
	end

	local value = Instance.new("IntValue")
	value.Name = "Clean Cash"
	value.Value = cleanCash
	value.Parent = leaderstats
end

function PlayerState.init(player: Player, loaded: SavedFields?): State
	local state: State = {
		CleanCash = (loaded and loaded.CleanCash) or GameConfig.StartingCleanCash,
		StreetCash = (loaded and loaded.StreetCash) or 0,
		Heat = (loaded and loaded.Heat) or 0,
		GangId = (loaded and loaded.GangId) or "Neutral",
		GangRank = (loaded and loaded.GangRank) or "Recruit",
		-- Type-guarded rather than trusted: Persistence raw-casts whatever the
		-- DataStore hands back, so a legacy or malformed entry here would make
		-- the first OwnedVehicles[id] = true throw.
		OwnedVehicles = if loaded and typeof(loaded.OwnedVehicles) == "table"
			then loaded.OwnedVehicles :: { [string]: boolean }
			else {},
		Inventory = if loaded and typeof(loaded.Inventory) == "table"
			then loaded.Inventory :: { [string]: number }
			else { Sidearm = 1 },
		HasCargoInsurance = (loaded and loaded.HasCargoInsurance) == true,
		EquippedWeaponId = "Sidearm",
		IsDowned = false,
		InSafehouse = false,
		PlaytimeSeconds = (loaded and loaded.PlaytimeSeconds) or 0,
		SessionStartedAt = os.time(),
		LastRaidedAt = (loaded and loaded.LastRaidedAt) or 0,
	}
	states[player] = state
	syncCleanCashView(player, state.CleanCash)
	PlayerState.pushOwnerView(player)
	return state
end

function PlayerState.getCleanCash(player: Player): number
	local state = states[player]
	return state and state.CleanCash or 0
end

function PlayerState.addCleanCash(player: Player, amount: number)
	local state = states[player]
	if not state or amount <= 0 then
		return
	end
	state.CleanCash += amount
	syncCleanCashView(player, state.CleanCash)
end

-- Checks affordability and debits in one step, with no yield in between, so two
-- concurrent spends can't both pass the check. Callers that yield before
-- committing (a text filter, a DataStore write) must call this AFTER the yield,
-- not before it.
function PlayerState.trySpendCleanCash(player: Player, amount: number): boolean
	local state = states[player]
	if not state or amount <= 0 or state.CleanCash < amount then
		return false
	end
	state.CleanCash -= amount
	syncCleanCashView(player, state.CleanCash)
	return true
end

function PlayerState.get(player: Player): State?
	return states[player]
end

function PlayerState.release(player: Player)
	states[player] = nil
end

-- Total playtime including the current session. Computed from a fixed session
-- start rather than accumulated, so calling it twice (a save on leave and again
-- on BindToClose) can't double-count.
function PlayerState.totalPlaytime(player: Player): number
	local state = states[player]
	if not state then
		return 0
	end
	return state.PlaytimeSeconds + math.max(0, os.time() - state.SessionStartedAt)
end

-- Pushes the fields a player is allowed to see about themselves to their own client only.
function PlayerState.pushOwnerView(player: Player)
	local state = states[player]
	if not state then
		return
	end
	stateUpdateRemote:FireClient(player, {
		Heat = state.Heat,
		StreetCash = state.StreetCash,
		GangId = state.GangId,
		GangRank = state.GangRank,
		HasCargoInsurance = state.HasCargoInsurance,
	})
end

-- Inventory travels on its own remote. It used to ride along with the state
-- push, which the Heat decay loop fires once a second per player — so a set that
-- only changes on purchase was being re-sent continuously.
function PlayerState.pushInventory(player: Player)
	local state = states[player]
	if not state then
		return
	end
	inventoryUpdateRemote:FireClient(player, {
		OwnedVehicles = state.OwnedVehicles,
	})
end

return PlayerState
