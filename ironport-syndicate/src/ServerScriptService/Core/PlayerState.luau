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
}

export type State = {
	StreetCash: number,
	Heat: number,
	GangId: string,
	GangRank: string,
	OwnedVehicles: { [string]: boolean },
	IsDowned: boolean,
	InSafehouse: boolean,
	JoinedAt: number,
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
		IsDowned = false,
		InSafehouse = false,
		JoinedAt = os.clock(),
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
