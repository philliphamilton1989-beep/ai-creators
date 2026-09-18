--!strict
-- Pawn shops: where found goods become money.
--
-- Shops pay in STREET Cash, not Clean. What you're selling is stolen, so the
-- proceeds are dirty and still have to go through laundering — that keeps the
-- pawn shop feeding the existing economy chain rather than bypassing it:
--
--   scavenge -> haul (weight) -> pawn (Street) -> launder (Clean) -> gear, crew
--
-- Shops pay a fraction of an item's Value, so fencing is always lossy. Better
-- shops pay more and sit further from where the loot is, which is the whole
-- reason to own a vehicle with 500 lb of space.

export type ShopTier = {
	DisplayName: string,
	-- Fraction of item Value paid out.
	PayoutRate: number,
	-- Categories this shop will touch at all.
	Accepts: { [string]: boolean },
}

local Tiers: { [string]: ShopTier } = {
	-- Corner shop: takes anything, pays badly. The one a new player can reach.
	CornerPawn = {
		DisplayName = "Corner Pawn",
		PayoutRate = 0.45,
		Accepts = { Valuable = true, Cargo = true, Kit = true, Weapon = false },
	},

	-- Scrapyard: bulk buyer. Pays well for heavy Cargo nobody else wants.
	Scrapyard = {
		DisplayName = "Dockside Scrapyard",
		PayoutRate = 0.55,
		Accepts = { Valuable = false, Cargo = true, Kit = false, Weapon = false },
	},

	-- Fence: discreet, pays properly, and will take the things a shopfront
	-- can't be seen handling.
	Fence = {
		DisplayName = "Back Room Fence",
		PayoutRate = 0.7,
		Accepts = { Valuable = true, Cargo = false, Kit = true, Weapon = true },
	},
}

return {
	Tiers = Tiers,

	-- How close you have to be to trade.
	InteractRangeStuds = 14,

	-- Above this Heat a shop won't deal: nobody launders for someone the police
	-- are actively looking for. Gives Heat a cost outside combat, and a reason to
	-- lie low before cashing out a big haul.
	MaxHeatToTrade = 60,
}
