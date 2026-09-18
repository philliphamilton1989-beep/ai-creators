--!strict
-- Purchase prompts and the client's view of what it's carrying.
--
-- PromptGamePassPurchase is a client API, so the prompt lives here — but this is
-- the ONLY thing the client decides. Whether a pass is owned, and what owning it
-- grants, is resolved server-side in GamePassService. Nothing here should ever
-- be treated as proof of ownership.
--
-- The prompt is a function for shop UI to call, deliberately not a call at load
-- time: firing it on join puts a purchase dialog in front of every player the
-- moment they spawn.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MonetizationConfig"))

local player = Players.LocalPlayer

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local inventoryRemotes = remotes:WaitForChild("InventoryRemotes")
local inventoryStateRemote = inventoryRemotes:WaitForChild("InventoryStateRemote") :: RemoteEvent

type InventoryView = {
	Items: { [string]: number },
	CarriedWeight: number,
	Capacity: number,
}

local ShopController = {}

ShopController.Items = {} :: { [string]: number }
ShopController.CarriedWeight = 0
ShopController.Capacity = 0
ShopController.InventoryChanged = Instance.new("BindableEvent")

-- Called by shop UI. Returns false when the pass isn't configured yet, rather
-- than prompting with an id of 0 and failing in the player's face.
function ShopController.promptPassPurchase(passKey: string): boolean
	local definition = MonetizationConfig.Passes[passKey]
	if not definition or definition.Id <= 0 then
		warn(("ShopController: pass %q has no configured Id yet"):format(passKey))
		return false
	end
	MarketplaceService:PromptGamePassPurchase(player, definition.Id)
	return true
end

inventoryStateRemote.OnClientEvent:Connect(function(data: InventoryView)
	if typeof(data) ~= "table" or typeof(data.Items) ~= "table" then
		return
	end
	ShopController.Items = data.Items
	ShopController.CarriedWeight = data.CarriedWeight or 0
	ShopController.Capacity = data.Capacity or 0
	ShopController.InventoryChanged:Fire()
end)

return ShopController
