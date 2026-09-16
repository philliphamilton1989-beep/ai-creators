--!strict
-- Territory capture and passive income.
--
-- Capture is a held contest, not a one-touch claim (per the GDD): a crew has to
-- stand in a node's zone uncontested for CaptureSeconds. If a second crew is
-- present the node is contested and progress bleeds away instead of advancing,
-- so a single player can't flip turf by running through it.
--
-- Territory is PER-SERVER, unlike crew membership which is global. Real-time
-- cross-server contested capture needs MemoryStoreService and a whole
-- reconciliation layer; keeping capture local to the server means the same crew
-- can hold the same block in several servers at once. That's a deliberate
-- scope call, not an oversight — see the note in the commit/handoff.
--
-- Zones are expected at Workspace.TerritoryNodes.<nodeId>.CaptureZone. Until
-- the level exists, capture idles with a one-time warning rather than erroring;
-- there is no sensible fallback for "who is standing here" without geometry.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = script.Parent.Parent:WaitForChild("Core")
local PlayerState = require(core:WaitForChild("PlayerState"))
local FactionService = require(script.Parent:WaitForChild("FactionService"))
local FactionConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("FactionConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local territoryUpdateRemote = remotes:WaitForChild("FactionRemotes"):WaitForChild("TerritoryUpdateRemote") :: RemoteEvent

local SNAPSHOT_INTERVAL_SECONDS = 5

type NodeState = {
	OwnerCrewId: string?,
	CapturingCrewId: string?,
	Progress: number,
	Contested: boolean,
}

local TerritoryService = {}

local nodes: { [string]: NodeState } = {}
-- Per node, not one module-wide flag: a single misconfigured node must not
-- silence the diagnostic for every other broken one.
local warnedMissingZone: { [string]: true } = {}

for nodeId in FactionConfig.Territory do
	nodes[nodeId] = {
		OwnerCrewId = nil,
		CapturingCrewId = nil,
		Progress = 0,
		Contested = false,
	}
end

-- Checked rather than cast: a CaptureZone that is a Model or Folder would reach
-- zone.CFrame and throw inside the Heartbeat handler, aborting the tick for
-- every other node once a second.
local function getCaptureZone(nodeId: string): BasePart?
	local folder = Workspace:FindFirstChild("TerritoryNodes")
	local nodeModel = folder and folder:FindFirstChild(nodeId)
	local zone = nodeModel and nodeModel:FindFirstChild("CaptureZone")
	if zone and zone:IsA("BasePart") then
		return zone
	end
	return nil
end

local function isInsideZone(zone: BasePart, position: Vector3): boolean
	local localPoint = zone.CFrame:PointToObjectSpace(position)
	local half = zone.Size / 2
	return math.abs(localPoint.X) <= half.X
		and math.abs(localPoint.Y) <= half.Y
		and math.abs(localPoint.Z) <= half.Z
end

-- Returns crewId -> headcount for players standing in the zone. Downed players
-- and players without a crew hold nothing.
local function crewsPresent(zone: BasePart): { [string]: number }
	local present: { [string]: number } = {}
	for _, player in Players:GetPlayers() do
		local state = PlayerState.get(player)
		if not state or state.IsDowned then
			continue
		end
		local crewId = FactionService.getCrewIdOf(player)
		if not crewId then
			continue
		end
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and isInsideZone(zone, root.Position) then
			present[crewId] = (present[crewId] or 0) + 1
		end
	end
	return present
end

local function nodePayload(nodeId: string, node: NodeState): { [string]: any }
	local config = FactionConfig.Territory[nodeId]
	return {
		NodeId = nodeId,
		DisplayName = config.DisplayName,
		OwnerCrewId = node.OwnerCrewId,
		CapturingCrewId = node.CapturingCrewId,
		Contested = node.Contested,
		Progress = node.Progress,
		CaptureSeconds = config.CaptureSeconds,
	}
end

-- Territory ownership is public: everyone can see which crew holds a block.
local function broadcastNode(nodeId: string, node: NodeState)
	territoryUpdateRemote:FireAllClients(nodePayload(nodeId, node))
end

local function advanceNode(nodeId: string, node: NodeState, dt: number): boolean
	local zone = getCaptureZone(nodeId)
	if not zone then
		if not warnedMissingZone[nodeId] then
			warnedMissingZone[nodeId] = true
			warn(
				("TerritoryService: no BasePart at Workspace.TerritoryNodes.%s.CaptureZone — this node is idle until the level provides one"):format(
					nodeId
				)
			)
		end
		return false
	end

	local config = FactionConfig.Territory[nodeId]
	local present = crewsPresent(zone)

	local distinctCrews = 0
	local leadCrewId: string? = nil
	local leadCount = 0
	for crewId, count in present do
		distinctCrews += 1
		if count > leadCount then
			leadCount = count
			leadCrewId = crewId
		end
	end

	local wasContested = node.Contested
	local previousOwner = node.OwnerCrewId
	local previousCapturing = node.CapturingCrewId

	if distinctCrews > 1 then
		-- Contested: nobody makes progress while a rival crew is standing here.
		node.Contested = true
		node.Progress = math.max(0, node.Progress - FactionConfig.ContestedDecayPerSecond * dt)
		if node.Progress == 0 then
			node.CapturingCrewId = nil
		end
	elseif distinctCrews == 1 and leadCrewId ~= node.OwnerCrewId then
		node.Contested = false
		if node.CapturingCrewId ~= leadCrewId then
			node.CapturingCrewId = leadCrewId
			node.Progress = 0
		end
		node.Progress += dt
		if node.Progress >= config.CaptureSeconds then
			node.OwnerCrewId = leadCrewId
			node.CapturingCrewId = nil
			node.Progress = 0
		end
	else
		-- Empty, or held by whoever already owns it: any partial capture bleeds off.
		node.Contested = false
		if node.Progress > 0 then
			node.Progress = math.max(0, node.Progress - FactionConfig.UnattendedDecayPerSecond * dt)
			if node.Progress == 0 then
				node.CapturingCrewId = nil
			end
		end
	end

	return node.OwnerCrewId ~= previousOwner
		or node.CapturingCrewId ~= previousCapturing
		or node.Contested ~= wasContested
end

-- A disbanded crew's turf goes neutral. Without this, the node keeps paying a
-- dead crew id: every minute queues a delta whose write is discarded, and the
-- node keeps broadcasting an owner that no longer exists.
FactionService.onCrewDisbanded(function(crewId: string)
	for nodeId, node in nodes do
		if node.OwnerCrewId == crewId then
			node.OwnerCrewId = nil
			node.CapturingCrewId = nil
			node.Progress = 0
			node.Contested = false
			broadcastNode(nodeId, node)
		end
	end
end)

local function payIncome()
	for nodeId, node in nodes do
		local crewId = node.OwnerCrewId
		if not crewId then
			continue
		end
		local config = FactionConfig.Territory[nodeId]
		local minutes = FactionConfig.IncomeIntervalSeconds / 60
		FactionService.creditTerritoryIncome(
			crewId,
			math.floor(config.IncomePerMinute * minutes),
			math.floor(FactionConfig.ContributionPerNodeMinute * minutes)
		)
	end
end

function TerritoryService.getOwner(nodeId: string): string?
	local node = nodes[nodeId]
	return node and node.OwnerCrewId
end

-- Highest vendor tier the crew currently has access to, for Defense vendors to
-- gate purchases on once they're built.
function TerritoryService.getVendorTier(crewId: string): number
	local tier = 0
	for nodeId, node in nodes do
		if node.OwnerCrewId == crewId then
			tier = math.max(tier, FactionConfig.Territory[nodeId].VendorTier)
		end
	end
	return tier
end

local accumulated = 0
RunService.Heartbeat:Connect(function(dt)
	accumulated += dt
	if accumulated < 1 then
		return
	end
	local step = accumulated
	accumulated = 0

	for nodeId, node in nodes do
		if advanceNode(nodeId, node, step) then
			broadcastNode(nodeId, node)
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(FactionConfig.IncomeIntervalSeconds)
		payIncome()
	end
end)

-- Periodic full snapshot so a joining client (or one that missed an event)
-- converges without every tick being broadcast.
task.spawn(function()
	while true do
		task.wait(SNAPSHOT_INTERVAL_SECONDS)
		for nodeId, node in nodes do
			broadcastNode(nodeId, node)
		end
	end
end)

return TerritoryService
