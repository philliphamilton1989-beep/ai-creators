--!strict
-- Spawns findable valuables around the map, with location deciding quality.
--
-- A spawn point is any BasePart under Workspace.ValuableSpawns carrying a
-- LootTable attribute. Level design decides where the good stuff is by which
-- table it names: ValuableStreet out in the open, ValuableAlley down the back
-- of a building, ValuableHidden somewhere that takes effort to reach. Nothing
-- about the tiering lives in code — it's a property of the place.
--
-- Spawned items are physical pickups with a ProximityPrompt, so the engine
-- enforces reach and Triggered arrives with the player who pressed it. Picking
-- one up respects carry weight: a flatscreen you can't lift stays where it is.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LootService = require(script.Parent:WaitForChild("LootService"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
local PlayerState = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerState"))
local InventoryConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("InventoryConfig"))
local LootConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("LootConfig"))

local ValuableSpawnService = {}

type SpawnPoint = {
	Anchor: BasePart,
	TableName: string,
	Current: Model?,
	RespawnAt: number,
}

local spawnPoints: { [BasePart]: SpawnPoint } = {}

-- Respawn is staggered around this rather than fixed, so a player who learns a
-- route can't time it to the second.
local RESPAWN_BASE_SECONDS = 150
local RESPAWN_JITTER_SECONDS = 90

local rng = Random.new()

local function clearSpawn(point: SpawnPoint)
	if point.Current and point.Current.Parent then
		point.Current:Destroy()
	end
	point.Current = nil
	point.RespawnAt = os.clock() + RESPAWN_BASE_SECONDS + rng:NextNumber(0, RESPAWN_JITTER_SECONDS)
end

local function onCollected(point: SpawnPoint, itemId: string, count: number, player: Player)
	local state = PlayerState.get(player)
	if not state or state.IsDowned then
		return
	end

	local taken = 0
	for _ = 1, count do
		local added = InventoryService.tryAddItem(player, itemId, 1)
		if not added then
			break
		end
		taken += 1
	end

	if taken == 0 then
		return -- too heavy, or stack full: it stays on the ground
	end

	if taken >= count then
		clearSpawn(point)
		return
	end

	-- Took some of a stack. Leave the rest in place with its label updated.
	local remaining = count - taken
	local model = point.Current
	local prompt = model and model:FindFirstChildWhichIsA("ProximityPrompt", true)
	if prompt then
		local definition = InventoryConfig.Items[itemId]
		prompt.ObjectText = ("%s x%d"):format(definition and definition.DisplayName or itemId, remaining)
		prompt:SetAttribute("RemainingCount", remaining)
	end
end

local function spawnAt(point: SpawnPoint)
	local contents = LootService.roll(point.TableName)
	if LootService.isEmpty(contents) then
		point.RespawnAt = os.clock() + RESPAWN_BASE_SECONDS
		return
	end

	-- One roll can produce several kinds; spawn the single most valuable so a
	-- point is one findable object, not a pile.
	local bestId, bestCount, bestValue = nil, 0, -1
	for itemId, count in contents do
		local definition = InventoryConfig.Items[itemId]
		local value = definition and definition.Value * count or 0
		if value > bestValue then
			bestId, bestCount, bestValue = itemId, count, value
		end
	end
	if not bestId then
		return
	end

	local definition = InventoryConfig.Items[bestId]
	if not definition then
		return
	end

	local model = Instance.new("Model")
	model.Name = "Valuable_" .. bestId

	local part = Instance.new("Part")
	part.Name = "Item"
	-- Roughly scaled to weight, so a TV reads as a lump and a ring reads as a
	-- glint before the player is close enough to see the prompt.
	local bulk = math.clamp(definition.Weight / 10, 0.4, 3)
	part.Size = Vector3.new(bulk, bulk * 0.6, bulk * 0.8)
	part.Color = if definition.Value >= 700 then Color3.fromRGB(198, 150, 74) else Color3.fromRGB(96, 92, 84)
	part.Material = if definition.Value >= 700 then Enum.Material.Metal else Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CFrame = point.Anchor.CFrame * CFrame.new(0, point.Anchor.Size.Y / 2 + bulk, 0)
	part.Parent = model
	model.PrimaryPart = part

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Take"
	prompt.ObjectText = if bestCount > 1
		then ("%s x%d"):format(definition.DisplayName, bestCount)
		else definition.DisplayName
	prompt.HoldDuration = 0.6
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("RemainingCount", bestCount)
	prompt.Parent = part

	model.Parent = Workspace
	point.Current = model
	point.RespawnAt = 0

	prompt.Triggered:Connect(function(player: Player)
		local remaining = prompt:GetAttribute("RemainingCount")
		onCollected(point, bestId :: string, if typeof(remaining) == "number" then remaining else bestCount, player)
	end)
end

local function registerSpawn(instance: Instance)
	if not instance:IsA("BasePart") or spawnPoints[instance] then
		return
	end

	local tableName = instance:GetAttribute("LootTable")
	if typeof(tableName) ~= "string" then
		warn(("ValuableSpawnService: %s has no LootTable attribute; skipping"):format(instance:GetFullName()))
		return
	end
	if not LootConfig.Tables[tableName] then
		warn(("ValuableSpawnService: %s names unknown loot table %q"):format(instance:GetFullName(), tableName))
		return
	end

	local point: SpawnPoint = {
		Anchor = instance,
		TableName = tableName,
		Current = nil,
		RespawnAt = 0,
	}
	spawnPoints[instance] = point
	spawnAt(point)
end

local function bindFolder(folder: Instance)
	for _, child in folder:GetChildren() do
		registerSpawn(child)
	end
	folder.ChildAdded:Connect(registerSpawn)
	folder.ChildRemoved:Connect(function(child)
		if child:IsA("BasePart") then
			local point = spawnPoints[child]
			if point and point.Current and point.Current.Parent then
				point.Current:Destroy()
			end
			spawnPoints[child] = nil
		end
	end)
end

task.spawn(function()
	while true do
		task.wait(10)
		local now = os.clock()
		for _, point in spawnPoints do
			if not point.Current and point.RespawnAt > 0 and now >= point.RespawnAt then
				spawnAt(point)
			end
		end
	end
end)

local folder = Workspace:FindFirstChild("ValuableSpawns")
if folder then
	bindFolder(folder)
else
	warn("ValuableSpawnService: no Workspace.ValuableSpawns folder — nothing spawns until the level provides one")
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "ValuableSpawns" then
			bindFolder(child)
		end
	end)
end

return ValuableSpawnService
