--!strict
-- What happens to carried gear when a player dies.
--
-- Death drops the bag; whoever reaches it first takes what they can carry. That
-- loss is the thing that makes weight limits, vehicle cargo and hauling into
-- decisions rather than bookkeeping.
--
-- Keeping your gear is therefore purchasable ONLY in advance, and only with
-- in-game Clean Cash: insurance is bought before a job, when the player is calm
-- and the cost is weighed against the risk. It is deliberately not a real-money
-- prompt at the moment of death — that is loss-framing plus time pressure
-- pointed at a mostly underage audience, and it would also make the entire risk
-- economy optional for anyone willing to pay.

return {
	-- How long a dropped bag survives before it despawns. Long enough for a
	-- fight to end and someone to walk back, short enough that the map doesn't
	-- fill with loot.
	DropLifetimeSeconds = 180,

	-- How close a looter has to be.
	LootRangeStuds = 12,

	-- Bought in advance with Clean Cash; consumed by the death it protects.
	-- Priced so insuring every run costs more than occasionally losing a bag,
	-- which keeps it a judgement call rather than a default.
	InsuranceCostCleanCash = 4500,

	-- Insurance covers weapons and kit, never Cargo. Hauling is the risk the
	-- economy is built on, so it stays uninsurable at any price.
	InsuredCategories = {
		Weapon = true,
		Kit = true,
		Cargo = false,
	},
}
