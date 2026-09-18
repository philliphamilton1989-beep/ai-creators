--!strict
-- Pawn shops: turns found goods into Street Cash.
--
-- Street, not Clean, deliberately. What's being sold is stolen, so the money is
-- dirty and still has to go through laundering. That keeps the shop inside the
-- economy chain instead of short-circuiting it.
--
-- A shop is any Model or BasePart under Workspace.PawnShops with a ShopTier
-- attribute naming a tier in PawnConfig. Which shop pays best, what it will
-- touch, and how far it sits from the good loot are all level-design decisions.
--
-- Everything here is re-validated server-side: the client names an item and a
-- count, and nothing else. Price, reach, heat and ownership all come from state.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = script.Parent.Parent:WaitForChild("Core")
local PlayerState = require(core:WaitForChild("PlayerState"))
local InventoryService = require(script.Parent.Parent:WaitForChild("Inventory"):WaitForChild("InventoryService"))
local InventoryConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("InventoryConfig"))
local PawnConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("PawnConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local pawnRemotes = remotes:WaitForChild("PawnRemotes")
local sellItemRemote = pawnRemotes:WaitForChild("SellItemRemote") :: RemoteFunction
local shopStateRemote = pawnRemotes:WaitForChild("ShopStateRemote") :: RemoteEvent

local PawnShopService = {}

local shops: { [Instance]: string } = {}

local function shopAnchor(shop: Instance): BasePart?
	if shop:IsA("BasePart") then
		return shop
	end
	if shop:IsA("Model") then
		return shop.PrimaryPart or shop:FindFirstChildWhichIsA("BasePart")
	end
	return nil
end

-- The shop a player is standing at, if any.
local function shopInReach(player: Player): (string?, string?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil, nil
	end

	for shop, tierName in shops do
		local anchor = shopAnchor(shop)
		if anchor and (anchor.Position - root.Position).Magnitude <= PawnConfig.InteractRangeStuds then
			return tierName, shop.Name
		end
	end
	return nil, nil
end

function PawnShopService.quote(tierName: string, itemId: string, count: number): number
	local tier = PawnConfig.Tiers[tierName]
	local definition = InventoryConfig.Items[itemId]
	if not tier or not definition then
		return 0
	end
	if not tier.Accepts[definition.Category] then
		return 0
	end
	return math.floor(definition.Value * tier.PayoutRate * count)
end

local function pushShopState(player: Player)
	local tierName, shopName = shopInReach(player)
	if not tierName then
		shopStateRemote:FireClient(player, { InReach = false })
		return
	end

	local tier = PawnConfig.Tiers[tierName]
	shopStateRemote:FireClient(player, {
		InReach = true,
		TierName = tierName,
		DisplayName = tier and tier.DisplayName or shopName,
		PayoutRate = tier and tier.PayoutRate or 0,
		Accepts = tier and tier.Accepts or {},
	})
end

sellItemRemote.OnServerInvoke = function(player: Player, itemId: string, count: number): (boolean, string, number)
	if typeof(itemId) ~= "string" or typeof(count) ~= "number" then
		return false, "InvalidArgs", 0
	end
	count = math.floor(count)
	if count <= 0 then
		return false, "InvalidCount", 0
	end

	local state = PlayerState.get(player)
	if not state or state.IsDowned then
		return false, "PlayerUnavailable", 0
	end

	local tierName = shopInReach(player)
	if not tierName then
		return false, "NoShopInReach", 0
	end

	-- Nobody fences for someone the police are actively looking for. Gives Heat
	-- a cost away from combat, and a reason to lie low before cashing out.
	if state.Heat > PawnConfig.MaxHeatToTrade then
		return false, "TooHot", 0
	end

	local definition = InventoryConfig.Items[itemId]
	if not definition then
		return false, "UnknownItem", 0
	end

	local tier = PawnConfig.Tiers[tierName]
	if not tier or not tier.Accepts[definition.Category] then
		return false, "ShopWontBuy", 0
	end

	local payout = PawnShopService.quote(tierName, itemId, count)
	if payout <= 0 then
		return false, "Worthless", 0
	end

	-- Remove first: if they didn't have it, no money is created.
	if not InventoryService.removeItem(player, itemId, count) then
		return false, "NotHeld", 0
	end

	state.StreetCash += payout
	PlayerState.pushOwnerView(player)

	return true, "Sold", payout
end

local function registerShop(instance: Instance)
	if shops[instance] then
		return
	end
	local tierName = instance:GetAttribute("ShopTier")
	if typeof(tierName) ~= "string" then
		return
	end
	if not PawnConfig.Tiers[tierName] then
		warn(("PawnShopService: %s names unknown shop tier %q"):format(instance:GetFullName(), tierName))
		return
	end
	shops[instance] = tierName
end

local function bindFolder(folder: Instance)
	for _, child in folder:GetChildren() do
		registerShop(child)
	end
	folder.ChildAdded:Connect(registerShop)
	folder.ChildRemoved:Connect(function(child)
		shops[child] = nil
	end)
end

-- Proximity is polled rather than evented: walking in and out of range is
-- continuous, and this keeps the client's SELL affordance honest without
-- attaching a region to every shopfront.
task.spawn(function()
	while true do
		task.wait(1)
		for _, player in Players:GetPlayers() do
			pushShopState(player)
		end
	end
end)

local folder = Workspace:FindFirstChild("PawnShops")
if folder then
	bindFolder(folder)
else
	warn("PawnShopService: no Workspace.PawnShops folder — nothing to sell to until the level provides one")
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "PawnShops" then
			bindFolder(child)
		end
	end)
end

return PawnShopService
