--!strict
-- Server-only private player state (Heat, Street Cash, downed state, etc).
-- Deliberately NOT stored as replicated Attributes on the Player instance:
-- Attributes replicate to every client by default, which would leak Heat and
-- Street Cash to every other player in the server and kill the stealth/heist
-- tension. Updates are pushed only to the owning client, over
-- PlayerStateUpdateRemote:FireClient.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local stateUpdateRemote = remotes:WaitForChild("CoreRemotes"):WaitForChild("PlayerStateUpdateRemote") :: RemoteEvent

export type SavedFields = {
	StreetCash: number?,
	Heat: number?,
	GangId: string?,
	GangRank: string?,
	OwnedVehicles: { [string]: boolean }?,
	PlaytimeSeconds: number?,
	LastRaidedAt: number?,
}

export type State = {
	StreetCash: number,
	Heat: number,
	GangId: string,
	GangRank: string,
	OwnedVehicles: { [string]: boolean },
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

function PlayerState.init(player: Player, loaded: SavedFields?): State
	local state: State = {
		StreetCash = (loaded and loaded.StreetCash) or 0,
		Heat = (loaded and loaded.Heat) or 0,
		GangId = (loaded and loaded.GangId) or "Neutral",
		GangRank = (loaded and loaded.GangRank) or "Recruit",
		OwnedVehicles = (loaded and loaded.OwnedVehicles) or {},
		EquippedWeaponId = "Sidearm",
		IsDowned = false,
		InSafehouse = false,
		PlaytimeSeconds = (loaded and loaded.PlaytimeSeconds) or 0,
		SessionStartedAt = os.time(),
		LastRaidedAt = (loaded and loaded.LastRaidedAt) or 0,
	}
	states[player] = state
	PlayerState.pushOwnerView(player)
	return state
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
		OwnedVehicles = state.OwnedVehicles,
	})
end

return PlayerState
