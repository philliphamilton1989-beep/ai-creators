--!strict
-- Mirrors server-broadcast heist phase updates into a BindableEvent-free local
-- signal other client UI scripts can poll via GetAttribute, matching the
-- pattern PlayerStateController uses for private state. Heist phase is public
-- (any player can see a vault is being breached), so this is fine to broadcast
-- to everyone rather than filtered per-client.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local phaseRemote = remotes:WaitForChild("HeistsRemotes"):WaitForChild("HeistPhaseRemote") :: RemoteEvent

local heistSitesFolder = Instance.new("Folder")
heistSitesFolder.Name = "ActiveHeistState"
heistSitesFolder.Parent = script

phaseRemote.OnClientEvent:Connect(function(payload: { [string]: any })
	local siteId = payload.SiteId
	if typeof(siteId) ~= "string" then
		return
	end

	local siteState = heistSitesFolder:FindFirstChild(siteId)
	if not siteState then
		siteState = Instance.new("Configuration")
		siteState.Name = siteId
		siteState.Parent = heistSitesFolder
	end

	-- Attributes can only hold simple types, so array fields like LootBagIds
	-- are intentionally skipped here — once the level exists, UI should read
	-- which bags are left directly off the physical loot bag parts in the
	-- world rather than off a replicated list.
	for key, value in payload do
		if key ~= "SiteId" and (typeof(value) == "string" or typeof(value) == "number" or typeof(value) == "boolean") then
			siteState:SetAttribute(key, value)
		end
	end
end)
