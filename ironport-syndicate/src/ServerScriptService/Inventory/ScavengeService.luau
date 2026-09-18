--!strict
-- Searchable containers: the world's source of items.
--
-- A container is any Model or BasePart under Workspace.ScavengeContainers with
-- a LootTable attribute naming a table in LootConfig. Level design places them
-- and picks the table; this service owns the rolling, the cooldown and the
-- prompt. No container needs a script of its own.
--
-- Contents are rolled once per restock and held, rather than rolled per player.
-- That makes a container a race — first there takes the good crate — instead of
-- a free draw for everyone who walks past, and it means a player who can't carry
-- it all leaves the rest for someone else.
--
-- Searching uses a ProximityPrompt, so distance is enforced by the engine and
-- Triggered arrives server-side with the player who actually pressed it. There
-- is no remote here to call from a script.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LootService = require(script.Parent:WaitForChild("LootService"))
local PlayerState = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerState"))
local LootConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("LootConfig"))

local ScavengeService = {}

type ContainerState = {
	TableName: string,
	Contents: { [string]: number },
	RestocksAt: number,
	Prompt: ProximityPrompt,
}

local containers: { [Instance]: ContainerState } = {}
local warnedMissingFolder = false

local function promptParent(container: Instance): BasePart?
	if container:IsA("BasePart") then
		return container
	end
	if container:IsA("Model") then
		return container.PrimaryPart or container:FindFirstChildWhichIsA("BasePart")
	end
	return nil
end

local function refreshPromptText(state: ContainerState)
	local definition = LootConfig.Tables[state.TableName]
	local label = definition and definition.DisplayName or "Container"

	if LootService.isEmpty(state.Contents) then
		state.Prompt.ActionText = "Empty"
		state.Prompt.ObjectText = label
		state.Prompt.Enabled = false
	else
		state.Prompt.ActionText = "Search"
		state.Prompt.ObjectText = label
		state.Prompt.Enabled = true
	end
end

local function restock(state: ContainerState)
	state.Contents = LootService.roll(state.TableName)
	state.RestocksAt = 0
	refreshPromptText(state)
end

local function onSearched(container: Instance, player: Player)
	local state = containers[container]
	if not state then
		return
	end

	local playerState = PlayerState.get(player)
	if not playerState or playerState.IsDowned then
		return
	end
	if LootService.isEmpty(state.Contents) then
		return
	end

	-- What the player can't carry stays in the container. Weight is the limit
	-- that makes a heavy container worth a second trip, or a vehicle.
	state.Contents = LootService.grantToPlayer(player, state.Contents)

	if LootService.isEmpty(state.Contents) then
		state.RestocksAt = os.clock() + LootConfig.ContainerRefreshSeconds
	end
	refreshPromptText(state)
end

local function registerContainer(container: Instance)
	if containers[container] then
		return
	end

	local tableName = container:GetAttribute("LootTable")
	if typeof(tableName) ~= "string" then
		warn(("ScavengeService: %s has no LootTable attribute; skipping"):format(container:GetFullName()))
		return
	end
	if not LootConfig.Tables[tableName] then
		warn(("ScavengeService: %s names unknown loot table %q"):format(container:GetFullName(), tableName))
		return
	end

	local anchor = promptParent(container)
	if not anchor then
		warn(("ScavengeService: %s has no BasePart to attach a prompt to"):format(container:GetFullName()))
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Search"
	prompt.HoldDuration = 1.2
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor

	local state: ContainerState = {
		TableName = tableName,
		Contents = {},
		RestocksAt = 0,
		Prompt = prompt,
	}
	containers[container] = state
	restock(state)

	prompt.Triggered:Connect(function(player: Player)
		onSearched(container, player)
	end)
end

local function bindFolder(folder: Instance)
	for _, child in folder:GetChildren() do
		registerContainer(child)
	end
	folder.ChildAdded:Connect(registerContainer)
	folder.ChildRemoved:Connect(function(child)
		containers[child] = nil
	end)
end

-- Restock sweep. Cheap enough to run on a slow tick, and keeps the cooldown in
-- one place rather than a task.delay per container that would leak on removal.
task.spawn(function()
	while true do
		task.wait(10)
		local now = os.clock()
		for _, state in containers do
			if state.RestocksAt > 0 and now >= state.RestocksAt then
				restock(state)
			end
		end
	end
end)

local folder = Workspace:FindFirstChild("ScavengeContainers")
if folder then
	bindFolder(folder)
else
	-- Same honest fallback the other level-dependent systems use: the code is
	-- ready, the level isn't built yet, and this says so once rather than erroring.
	if not warnedMissingFolder then
		warnedMissingFolder = true
		warn("ScavengeService: no Workspace.ScavengeContainers folder — nothing to scavenge until the level provides one")
	end
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "ScavengeContainers" then
			bindFolder(child)
		end
	end)
end

function ScavengeService.getContainerCount(): number
	local count = 0
	for _ in containers do
		count += 1
	end
	return count
end

return ScavengeService
