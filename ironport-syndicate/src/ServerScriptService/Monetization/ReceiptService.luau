--!strict
-- Developer product purchases.
--
-- ProcessReceipt is the highest-stakes callback in a Roblox game: it handles
-- real money, and Roblox CALLS IT REPEATEDLY until it returns PurchaseGranted.
-- Three rules follow from that, and all three are load-bearing:
--
--  1. It must be idempotent. A retry after a successful grant must not grant
--     again. Every processed PurchaseId is recorded, and a receipt whose id is
--     already on file is acknowledged without re-granting.
--  2. The record must be durable BEFORE returning PurchaseGranted. Granting
--     first and recording second means a crash in between double-grants on the
--     next retry.
--  3. Anything unresolved returns NotProcessedYet, never PurchaseGranted.
--     Roblox will retry; the player keeps their Robux in the meantime. Returning
--     Granted on a failure takes their money and gives them nothing.
--
-- Only one ProcessReceipt callback may exist per game, so this module is the
-- single place any product is granted.

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local core = script.Parent.Parent:WaitForChild("Core")
local PlayerState = require(core:WaitForChild("PlayerState"))
local DataStoreRetry = require(core:WaitForChild("DataStoreRetry"))
local MonetizationConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MonetizationConfig"))

local receiptStore = DataStoreService:GetDataStore("IronportSyndicate_Receipts_v1")

local ReceiptService = {}

-- Enough history to cover any realistic retry window without growing the record
-- without bound.
local MAX_TRACKED_RECEIPTS = 50

local function productForId(productId: number): (string?, MonetizationConfig.ProductDefinition?)
	for key, definition in MonetizationConfig.Products do
		if definition.Id == productId and definition.Id > 0 then
			return key, definition
		end
	end
	return nil, nil
end

-- Applies a product's effect to live state. Returns false if it couldn't be
-- applied, which becomes NotProcessedYet rather than a silent loss.
local function applyGrant(player: Player, definition: MonetizationConfig.ProductDefinition): boolean
	local state = PlayerState.get(player)
	if not state then
		return false
	end

	local grant = definition.Grant
	local amount = definition.GrantAmount

	if grant == "CleanCash" then
		PlayerState.addCleanCash(player, amount)
	elseif grant == "DeathSaveCharge" then
		state.DeathSaveCharges += amount
	elseif grant == "WarpCharge" then
		state.WarpCharges += amount
	elseif grant == "RaidShieldHours" then
		-- Extends from now, or from the existing expiry if one is still running,
		-- so buying a second shield never shortens the first.
		local now = os.time()
		local base = math.max(now, state.RaidShieldUntil)
		state.RaidShieldUntil = base + amount * 3600
	else
		warn(("ReceiptService: product %q has unknown grant %q"):format(definition.DisplayName, grant))
		return false
	end

	PlayerState.pushOwnerView(player)
	return true
end

-- Records the receipt and the grant together. Returns true only once the write
-- is durable — the caller must not report success before this does.
local function commitReceipt(player: Player, purchaseId: string, definition: MonetizationConfig.ProductDefinition): boolean
	local key = "Receipts_" .. player.UserId
	local alreadyProcessed = false

	local ok = DataStoreRetry.run("Receipt " .. purchaseId, function()
		receiptStore:UpdateAsync(key, function(stored: { string }?): { string }
			local history = stored or {}

			if table.find(history, purchaseId) then
				-- A retry of something already granted. Acknowledge it without
				-- granting a second time.
				alreadyProcessed = true
				return history
			end

			table.insert(history, purchaseId)
			while #history > MAX_TRACKED_RECEIPTS do
				table.remove(history, 1)
			end
			return history
		end)
	end)

	if not ok then
		return false -- unresolved; Roblox will retry
	end
	if alreadyProcessed then
		return true -- already honoured
	end

	-- Applied only after the receipt is durably on file. If the grant itself
	-- fails here the receipt is still recorded, which is the safe direction:
	-- a support-recoverable missing grant beats an unbounded double-grant loop.
	if not applyGrant(player, definition) then
		warn(("ReceiptService: receipt %s recorded but grant failed for %s"):format(purchaseId, player.Name))
	end
	return true
end

function ReceiptService.promptable(productKey: string): boolean
	local definition = MonetizationConfig.Products[productKey]
	return definition ~= nil and definition.Id > 0
end

MarketplaceService.ProcessReceipt = function(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- They left before it landed. Roblox retries when they're next in a
		-- server, so this is a wait rather than a failure.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local productKey, definition = productForId(receiptInfo.ProductId)
	if not definition then
		-- An id the game doesn't recognise. Retrying forever helps nobody, but
		-- granting nothing and accepting the money is worse, so leave it
		-- unprocessed and loud.
		warn(("ReceiptService: unrecognised ProductId %d for %s"):format(receiptInfo.ProductId, player.Name))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local granted = commitReceipt(player, tostring(receiptInfo.PurchaseId), definition)
	if not granted then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	print(("ReceiptService: granted %s to %s"):format(productKey or "product", player.Name))
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

return ReceiptService
