--!strict
-- Mirrors the private, server-pushed state (Heat, Street Cash, Gang) into local
-- attributes on LocalPlayer for other client UI scripts to read. SetAttribute
-- here only ever affects this client's own view — it does not replicate back
-- to the server or to other players.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local stateUpdateRemote = remotes:WaitForChild("CoreRemotes"):WaitForChild("PlayerStateUpdateRemote") :: RemoteEvent

type OwnerView = {
	Heat: number,
	StreetCash: number,
	GangId: string,
	GangRank: string,
}

stateUpdateRemote.OnClientEvent:Connect(function(data: OwnerView)
	player:SetAttribute("LocalHeat", data.Heat)
	player:SetAttribute("LocalStreetCash", data.StreetCash)
	player:SetAttribute("LocalGangId", data.GangId)
	player:SetAttribute("LocalGangRank", data.GangRank)
end)
