--!strict
-- Drops a player's carried gear where they died, and lets anyone standing over
-- it take what they can carry.
--
-- Looting goes through a ProximityPrompt rather than a remote the client can
-- call at will: the prompt's own MaxActivationDistance enforces proximity in the
-- engine, and Triggered fires on the server with the player who actually
-- pressed it. There is no client-supplied position to spoof.
--
-- Insurance, where a player has it, is consumed by the death it protects and
-- covers weapons and kit only. Cargo always drops — see DeathDropConfig for why.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = script.Parent.Parent:WaitForChild("Core")
local PlayerState = require(core:WaitForChild("PlayerState"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
local InventoryConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("InventoryConfig"))
local DeathDropConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("DeathDropConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local inventoryRemotes = remotes:WaitForChild("InventoryRemotes")
local buyInsuranceRemote = inventoryRemotes:WaitForChild("BuyCargoInsuranceRemote") :: RemoteFunction

local DeathDropService = {}

local drops: { [Model]: { [string]: number } } = {}

local function isEmpty(contents: { [string]: number }): boolean
	for _ in contents do
		return false
	end
	return true
end

local function despawnDrop(model: Model)
	drops[model] = nil
	if model.Parent then
		model:Destroy()
	end
end

local function lootDrop(model: Model, looter: Player)
	local contents = drops[model]
	if not contents then
		return
	end

	local state = PlayerState.get(looter)
	if not state or state.IsDowned then
		return
	end

	-- Take what fits, leave the rest. A bag that can't be emptied in one trip is
	-- a decision about what to prioritise, not a failure.
	local tookAnything = false
	for itemId, count in contents do
		for _ = 1, count do
			local added = InventoryService.tryAddItem(looter, itemId, 1)
			if not added then
				break
			end
			tookAnything = true
			local remaining = (contents[itemId] or 0) - 1
			contents[itemId] = if remaining > 0 then remaining else nil
		end
	end

	if tookAnything and isEmpty(contents) then
		despawnDrop(model)
	end
end

local function createDrop(position: Vector3, contents: { [string]: number })
	if isEmpty(contents) then
		return
	end

	local model = Instance.new("Model")
	model.Name = "DroppedGear"

	local part = Instance.new("Part")
	part.Name = "Bag"
	part.Size = Vector3.new(2.5, 1.2, 1.4)
	part.Color = Color3.fromRGB(46, 42, 36)
	part.Material = Enum.Material.Fabric
	part.Anchored = true
	part.CanCollide = false
	part.CFrame = CFrame.new(position)
	part.Parent = model
	model.PrimaryPart = part

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Loot"
	prompt.ObjectText = "Dropped Gear"
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = DeathDropConfig.LootRangeStuds
	prompt.RequiresLineOfSight = false
	prompt.Parent = part

	model.Parent = Workspace
	drops[model] = contents

	prompt.Triggered:Connect(function(looter: Player)
		lootDrop(model, looter)
	end)

	task.delay(DeathDropConfig.DropLifetimeSeconds, function()
		despawnDrop(model)
	end)
end

-- Splits the inventory into what insurance keeps and what hits the ground.
local function partitionInventory(inventory: { [string]: number }, insured: boolean): ({ [string]: number }, { [string]: number })
	local kept: { [string]: number } = {}
	local dropped: { [string]: number } = {}

	for itemId, count in inventory do
		local definition = InventoryConfig.Items[itemId]
		local covered = insured
			and definition ~= nil
			and DeathDropConfig.InsuredCategories[definition.Category] == true
		if covered then
			kept[itemId] = count
		else
			dropped[itemId] = count
		end
	end

	return kept, dropped
end

local function onDeath(player: Player, deathPosition: Vector3)
	local state = PlayerState.get(player)
	if not state then
		return
	end

	-- A Death Save is the stronger protection and is spent first: it keeps
	-- everything, Cargo included, where Clean Cash insurance only covers gear.
	-- Consumed here, at the death it was bought in advance to cover — there is
	-- deliberately no prompt at this moment, which is the whole design rule.
	if state.DeathSaveCharges > 0 then
		state.DeathSaveCharges -= 1
		PlayerState.pushOwnerView(player)
		InventoryService.onPlayerReady(player)
		return
	end

	local insured = state.HasCargoInsurance
	local kept, dropped = partitionInventory(state.Inventory, insured)

	state.Inventory = kept
	if insured then
		-- Consumed by the death it covered, whether or not anything was actually
		-- at risk; that's what stops it being a permanent purchase.
		state.HasCargoInsurance = false
	end

	InventoryService.onPlayerReady(player) -- re-push inventory and encumbrance
	createDrop(deathPosition, dropped)
end

buyInsuranceRemote.OnServerInvoke = function(player: Player): (boolean, string)
	local state = PlayerState.get(player)
	if not state then
		return false, "PlayerUnavailable"
	end
	if state.HasCargoInsurance then
		return false, "AlreadyInsured"
	end
	if not PlayerState.trySpendCleanCash(player, DeathDropConfig.InsuranceCostCleanCash) then
		return false, "CannotAfford"
	end

	state.HasCargoInsurance = true
	PlayerState.pushOwnerView(player)
	return true, "Insured"
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if not humanoid then
			return
		end
		humanoid.Died:Connect(function()
			-- Read the position before the character starts falling apart.
			local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local position = root and root.Position or character:GetPivot().Position
			onDeath(player, position)
		end)
	end)
end)

return DeathDropService
