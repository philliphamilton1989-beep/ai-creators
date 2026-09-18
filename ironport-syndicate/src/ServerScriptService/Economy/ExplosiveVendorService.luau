--!strict
-- Sells anti-armor hardware. Implements BuyExplosiveRemote, which has been
-- declared in the manifest since the original scaffold with no handler behind
-- it.
--
-- This exists so the counter to armor is RELIABLE. A rocket that only drops
-- from Zone 3 vaults would mean armor is countered by luck, which in practice
-- means a crew that can afford a Raider is unanswerable on any night the dice
-- go their way. Being able to walk to a fence and buy the answer is what makes
-- the vehicle a purchase rather than a trump card.
--
-- Sold only at the Fence tier: a shopfront cannot be seen handling rockets, and
-- it gives the highest-trust vendor something to be the highest-trust vendor of.
-- Priced above the item's own Value so buying is worse than looting, which
-- keeps Zone 3 worth raiding.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = script.Parent.Parent:WaitForChild("Core")
local PlayerState = require(core:WaitForChild("PlayerState"))
local InventoryService = require(script.Parent.Parent:WaitForChild("Inventory"):WaitForChild("InventoryService"))
local Numeric = require(ReplicatedStorage:WaitForChild("Libraries"):WaitForChild("Numeric"))
local PawnConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("PawnConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local buyExplosiveRemote = remotes:WaitForChild("DefenseVendorRemotes"):WaitForChild("BuyExplosiveRemote") :: RemoteFunction

local ExplosiveVendorService = {}

-- Clean Cash prices, deliberately above each item's own Value so fencing what
-- you loot beats buying it.
local Catalog: { [string]: number } = {
	RPGLauncher = 6000,
	RocketRound = 1400,
	BreachingCharge = 700,
}

local VENDOR_TIER = "Fence"

local function atFence(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end

	local folder = Workspace:FindFirstChild("PawnShops")
	if not folder then
		return false
	end

	for _, shop in folder:GetChildren() do
		if shop:GetAttribute("ShopTier") ~= VENDOR_TIER then
			continue
		end
		local anchor = if shop:IsA("BasePart")
			then shop
			else (shop :: Model).PrimaryPart or shop:FindFirstChildWhichIsA("BasePart")
		if anchor and (anchor.Position - root.Position).Magnitude <= PawnConfig.InteractRangeStuds then
			return true
		end
	end
	return false
end

buyExplosiveRemote.OnServerInvoke = function(player: Player, itemId: string, rawCount: number): (boolean, string)
	if typeof(itemId) ~= "string" then
		return false, "InvalidItem"
	end
	local count = Numeric.toCashAmount(rawCount)
	if not count then
		return false, "InvalidCount"
	end

	local unitPrice = Catalog[itemId]
	if not unitPrice then
		return false, "NotSoldHere"
	end

	local state = PlayerState.get(player)
	if not state or state.IsDowned then
		return false, "PlayerUnavailable"
	end
	if not atFence(player) then
		return false, "NoFenceInReach"
	end
	-- The fence deals in hardware, not in attention.
	if state.Heat > PawnConfig.MaxHeatToTrade then
		return false, "TooHot"
	end

	-- Carry capacity is checked by adding first: a launcher and three rockets is
	-- 42 lb, and a player who cannot lift what they are buying should be told
	-- before their money moves rather than after.
	local added, reason = InventoryService.tryAddItem(player, itemId, count)
	if not added then
		return false, reason
	end

	if not PlayerState.trySpendCleanCash(player, unitPrice * count) then
		-- Roll the goods back; nothing is created without being paid for.
		InventoryService.removeItem(player, itemId, count)
		return false, "CannotAfford"
	end

	return true, "Purchased"
end

return ExplosiveVendorService
