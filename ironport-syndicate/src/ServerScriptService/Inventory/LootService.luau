--!strict
-- Rolls loot tables and hands the results to players.
--
-- Every roll happens here, on the server. The client never names a table, never
-- sees the weights before a roll, and never reports what it got — it is told.
--
-- Uses its own Random rather than math.random: the global generator is shared
-- state that any other script can reseed, and loot is exactly the place where a
-- predictable sequence would matter.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
local LootConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("LootConfig"))
local InventoryConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("InventoryConfig"))

local LootService = {}

local rng = Random.new()

local function pickEntry(entries: { LootConfig.LootEntry }): LootConfig.LootEntry?
	local total = 0
	for _, entry in entries do
		total += math.max(0, entry.Weight)
	end
	if total <= 0 then
		return nil
	end

	local roll = rng:NextNumber() * total
	local cumulative = 0
	for _, entry in entries do
		cumulative += math.max(0, entry.Weight)
		if roll <= cumulative then
			return entry
		end
	end
	-- Only reachable through floating-point drift at the very top of the range.
	return entries[#entries]
end

-- Rolls a table into an itemId -> count map. Unknown item ids are skipped rather
-- than granted, so a typo in config can't mint an item that has no weight and
-- therefore bypasses every carry limit.
function LootService.roll(tableName: string): { [string]: number }
	local definition = LootConfig.Tables[tableName]
	if not definition then
		warn(("LootService: unknown loot table %q"):format(tableName))
		return {}
	end

	local contents: { [string]: number } = {}
	local rolls = rng:NextInteger(definition.RollsMin, definition.RollsMax)

	for _ = 1, rolls do
		local entry = pickEntry(definition.Entries)
		if entry and InventoryConfig.Items[entry.ItemId] then
			local count = rng:NextInteger(entry.MinCount, entry.MaxCount)
			if count > 0 then
				contents[entry.ItemId] = (contents[entry.ItemId] or 0) + count
			end
		elseif entry then
			warn(("LootService: table %q references unknown item %q"):format(tableName, entry.ItemId))
		end
	end

	return contents
end

-- Grants what fits under the player's weight and stack limits, and returns
-- whatever didn't. Callers decide what happens to the remainder: a container
-- keeps it, a heist bag leaves it on the floor.
function LootService.grantToPlayer(player: Player, contents: { [string]: number }): { [string]: number }
	local leftover: { [string]: number } = {}

	for itemId, count in contents do
		local remaining = count
		for _ = 1, count do
			local added = InventoryService.tryAddItem(player, itemId, 1)
			if not added then
				break
			end
			remaining -= 1
		end
		if remaining > 0 then
			leftover[itemId] = remaining
		end
	end

	return leftover
end

function LootService.isEmpty(contents: { [string]: number }): boolean
	for _ in contents do
		return false
	end
	return true
end

return LootService
