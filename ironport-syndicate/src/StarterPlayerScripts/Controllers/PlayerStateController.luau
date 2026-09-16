--!strict
-- Mirrors the private, server-pushed state into a form client UI can read.
--
-- Simple scalars go into attributes on LocalPlayer (SetAttribute here only ever
-- affects this client's own view — it does not replicate back to the server or
-- to other players). Owned vehicles can't: attributes hold only simple types, so
-- the set is kept on this module instead.
--
-- A ModuleScript rather than a LocalScript, matching FactionController, because
-- UI has to be able to require it — a LocalScript's return value is unreachable.
-- ClientBootstrap requires it once so the listeners are live before any UI is
-- built.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local coreRemotes = remotes:WaitForChild("CoreRemotes")
local stateUpdateRemote = coreRemotes:WaitForChild("PlayerStateUpdateRemote") :: RemoteEvent
local inventoryUpdateRemote = coreRemotes:WaitForChild("InventoryUpdateRemote") :: RemoteEvent

type OwnerView = {
	Heat: number,
	StreetCash: number,
	GangId: string,
	GangRank: string,
}

type InventoryView = {
	OwnedVehicles: { [string]: boolean },
}

local PlayerStateController = {}

PlayerStateController.OwnedVehicles = {} :: { [string]: boolean }
PlayerStateController.InventoryChanged = Instance.new("BindableEvent")

stateUpdateRemote.OnClientEvent:Connect(function(data: OwnerView)
	player:SetAttribute("LocalHeat", data.Heat)
	player:SetAttribute("LocalStreetCash", data.StreetCash)
	player:SetAttribute("LocalGangId", data.GangId)
	player:SetAttribute("LocalGangRank", data.GangRank)
end)

inventoryUpdateRemote.OnClientEvent:Connect(function(data: InventoryView)
	if typeof(data) ~= "table" or typeof(data.OwnedVehicles) ~= "table" then
		return
	end
	PlayerStateController.OwnedVehicles = data.OwnedVehicles
	PlayerStateController.InventoryChanged:Fire()
end)

return PlayerStateController
