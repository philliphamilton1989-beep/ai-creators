--!strict
-- Client-side cache of the player's own crew, any pending invite, and territory
-- ownership, for UI to read on demand rather than having to catch the event that
-- delivered it. A ModuleScript rather than a LocalScript so UI can require it;
-- ClientBootstrap requires it once so the listeners are registered even before
-- any UI exists.
--
-- Crew roster arrives only for members (the server uses FireClient); territory
-- ownership is public and broadcast to everyone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local factionRemotes = remotes:WaitForChild("FactionRemotes")
local crewUpdateRemote = factionRemotes:WaitForChild("CrewUpdateRemote") :: RemoteEvent
local crewInviteRemote = factionRemotes:WaitForChild("CrewInviteRemote") :: RemoteEvent
local territoryUpdateRemote = factionRemotes:WaitForChild("TerritoryUpdateRemote") :: RemoteEvent

type Payload = { [string]: any }

local FactionController = {}

FactionController.Crew = nil :: Payload?
FactionController.PendingInvite = nil :: Payload?
FactionController.Territory = {} :: { [string]: Payload }

-- Fires whenever any of the above changes, so UI can redraw without polling.
FactionController.Changed = Instance.new("BindableEvent")

crewUpdateRemote.OnClientEvent:Connect(function(payload: Payload)
	FactionController.Crew = if payload and payload.CrewId then payload else nil
	FactionController.Changed:Fire("Crew")
end)

crewInviteRemote.OnClientEvent:Connect(function(payload: Payload)
	FactionController.PendingInvite = payload
	FactionController.Changed:Fire("Invite")
end)

territoryUpdateRemote.OnClientEvent:Connect(function(payload: Payload)
	local nodeId = payload and payload.NodeId
	if typeof(nodeId) ~= "string" then
		return
	end
	FactionController.Territory[nodeId] = payload
	FactionController.Changed:Fire("Territory")
end)

return FactionController
