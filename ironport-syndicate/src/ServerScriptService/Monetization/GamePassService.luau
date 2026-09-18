--!strict
-- Server-authoritative game pass ownership.
--
-- The client may only ever ASK for a purchase prompt (PromptGamePassPurchase is
-- a client API). It must never be the thing that says whether a pass is owned:
-- that answer decides what a player gets, so it comes from
-- UserOwnsGamePassAsync here, on the server.
--
-- Ownership is resolved once on join and again when a purchase completes, then
-- cached. UserOwnsGamePassAsync is a web call — it yields, it is rate limited,
-- and it throws on failure, so calling it per use would be both slow and
-- fragile.
--
-- Failure is treated as "not owned, and don't cache that". Caching a failed
-- lookup would silently strip a paying player of what they bought until they
-- rejoined; leaving it uncached means the next check retries.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MonetizationConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MonetizationConfig"))

local GamePassService = {}

-- player -> passId -> owned
local ownership: { [Player]: { [number]: boolean } } = {}

local passChanged = Instance.new("BindableEvent")
-- Fires (player, passKey) when a pass is newly granted, so dependent systems
-- (carry capacity, for one) can recompute rather than poll.
GamePassService.PassGranted = passChanged.Event

local function cacheFor(player: Player): { [number]: boolean }
	local cached = ownership[player]
	if not cached then
		cached = {}
		ownership[player] = cached
	end
	return cached
end

local function fetchOwnership(player: Player, passId: number): boolean?
	if passId <= 0 then
		-- Unconfigured pass id. Not an error worth spamming about: it just means
		-- the pass hasn't been published and its id pasted into config yet.
		return false
	end
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	if not ok then
		warn(("GamePassService: ownership check failed for %s / pass %d: %s"):format(player.Name, passId, tostring(owns)))
		return nil
	end
	return owns == true
end

-- Returns whether the player owns the pass, using the session cache. A lookup
-- that has never succeeded is retried rather than assumed false forever.
function GamePassService.ownsPass(player: Player, passKey: string): boolean
	local definition = MonetizationConfig.Passes[passKey]
	if not definition then
		return false
	end

	local cached = cacheFor(player)
	local known = cached[definition.Id]
	if known ~= nil then
		return known
	end

	local owns = fetchOwnership(player, definition.Id)
	if owns == nil then
		return false -- unresolved; deliberately not cached, so it retries
	end
	cached[definition.Id] = owns
	return owns
end

function GamePassService.onPlayerReady(player: Player)
	-- Warm the cache up front so the first gameplay check doesn't yield on a web
	-- call mid-action.
	for passKey in MonetizationConfig.Passes do
		GamePassService.ownsPass(player, passKey)
	end
end

-- Granting on purchase rather than on next join. The client-side
-- PromptGamePassPurchaseFinished signal is not authoritative, so this listens on
-- the server.
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, wasPurchased: boolean)
	if not wasPurchased then
		return
	end
	cacheFor(player)[passId] = true

	for passKey, definition in MonetizationConfig.Passes do
		if definition.Id == passId then
			passChanged:Fire(player, passKey)
			break
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	ownership[player] = nil
end)

return GamePassService
