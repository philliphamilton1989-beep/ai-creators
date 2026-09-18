--!strict
-- Carried gear and the weight limit over it.
--
-- Capacity is BaseCarryWeight, doubled while the player owns the Backpack pass.
-- Heist loot and Street Cash are deliberately weightless, so the pass raises how
-- much kit you can bring to a job and never how much you can carry out of one.
--
-- Everything here is server-side. The client is told what it holds; it never
-- says what it holds.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = script.Parent.Parent:WaitForChild("Core")
local PlayerState = require(core:WaitForChild("PlayerState"))
local GamePassService = require(script.Parent.Parent:WaitForChild("Monetization"):WaitForChild("GamePassService"))
local InventoryConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("InventoryConfig"))
local MonetizationConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MonetizationConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local inventoryRemotes = remotes:WaitForChild("InventoryRemotes")
local inventoryStateRemote = inventoryRemotes:WaitForChild("InventoryStateRemote") :: RemoteEvent
local dropItemRemote = inventoryRemotes:WaitForChild("DropItemRemote") :: RemoteFunction

local InventoryService = {}

function InventoryService.getCapacity(player: Player): number
	local base = InventoryConfig.BaseCarryWeight
	if GamePassService.ownsPass(player, "Backpack") then
		return base * MonetizationConfig.BackpackCarryMultiplier
	end
	return base
end

function InventoryService.getCarriedWeight(player: Player): number
	local state = PlayerState.get(player)
	if not state then
		return 0
	end
	local total = 0
	for itemId, count in state.Inventory do
		local definition = InventoryConfig.Items[itemId]
		if definition then
			total += definition.Weight * count
		end
	end
	return total
end

local function pushInventory(player: Player)
	local state = PlayerState.get(player)
	if not state then
		return
	end
	inventoryStateRemote:FireClient(player, {
		Items = state.Inventory,
		CarriedWeight = InventoryService.getCarriedWeight(player),
		Capacity = InventoryService.getCapacity(player),
	})
end

-- Applies the overweight movement penalty. Only reachable by losing capacity
-- while loaded (which today means a pass lapsing between sessions), since a
-- pickup that would exceed capacity is refused outright.
local function applyEncumbrance(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local state = PlayerState.get(player)
	if state and state.IsDowned then
		return -- the bleedout state owns WalkSpeed while downed
	end

	local overweight = InventoryService.getCarriedWeight(player) > InventoryService.getCapacity(player)
	humanoid.WalkSpeed = if overweight then InventoryConfig.OverweightWalkSpeed else InventoryConfig.NormalWalkSpeed
end

-- Returns false (with a reason) rather than partially adding: a pickup either
-- fits entirely or doesn't happen.
function InventoryService.tryAddItem(player: Player, itemId: string, count: number): (boolean, string)
	local definition = InventoryConfig.Items[itemId]
	if not definition then
		return false, "UnknownItem"
	end
	if count <= 0 or count ~= math.floor(count) then
		return false, "InvalidCount"
	end

	local state = PlayerState.get(player)
	if not state then
		return false, "PlayerUnavailable"
	end

	local held = state.Inventory[itemId] or 0
	if held + count > definition.MaxStack then
		return false, "StackLimit"
	end

	local added = definition.Weight * count
	if InventoryService.getCarriedWeight(player) + added > InventoryService.getCapacity(player) then
		return false, "TooHeavy"
	end

	state.Inventory[itemId] = held + count
	pushInventory(player)
	applyEncumbrance(player)
	return true, "Added"
end

function InventoryService.removeItem(player: Player, itemId: string, count: number): boolean
	local state = PlayerState.get(player)
	if not state or count <= 0 then
		return false
	end

	local held = state.Inventory[itemId] or 0
	if held < count then
		return false
	end

	local remaining = held - count
	state.Inventory[itemId] = if remaining > 0 then remaining else nil
	pushInventory(player)
	applyEncumbrance(player)
	return true
end

function InventoryService.onPlayerReady(player: Player)
	pushInventory(player)
	applyEncumbrance(player)
end

dropItemRemote.OnServerInvoke = function(player: Player, itemId: string, count: number): (boolean, string)
	if typeof(itemId) ~= "string" or typeof(count) ~= "number" then
		return false, "InvalidArgs"
	end
	if not InventoryService.removeItem(player, itemId, math.floor(count)) then
		return false, "NotHeld"
	end
	return true, "Dropped"
end

-- Buying the pass mid-session raises capacity immediately, rather than on the
-- next rejoin.
GamePassService.PassGranted:Connect(function(player: Player, passKey: string)
	if passKey ~= "Backpack" then
		return
	end
	pushInventory(player)
	applyEncumbrance(player)
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		-- A fresh character resets WalkSpeed, so the penalty has to be re-applied.
		task.defer(applyEncumbrance, player)
	end)
end)

return InventoryService
