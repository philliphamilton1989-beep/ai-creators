--!strict
-- Heist site definitions. Pure data, so client UI can read squad size, payout
-- range, etc. directly by requiring this module — no remote needed for
-- read-only shared config. The server (HeistService) is still the only thing
-- that can ever advance a heist's actual state.

export type HeistSite = {
	DisplayName: string,
	MinSquadSize: number,
	MaxSquadSize: number,
	BreachSeconds: number,
	HeistTimeLimitSeconds: number,
	CooldownSeconds: number,
	LootBagCount: number,
	LootBagValueMin: number,
	LootBagValueMax: number,
	HeatOnBreach: number,
	HeatPerLootBag: number,
}

local HeistConfig: { Sites: { [string]: HeistSite }, PickupCooldownSeconds: number } = {
	-- Minimum gap between one player's loot pickups. Without pacing, a single
	-- participant can claim every bag in one frame, which defeats both the
	-- heist time limit and any notion of splitting the take across the crew.
	PickupCooldownSeconds = 1.5,

	Sites = {
		IronportSavingsVault = {
			DisplayName = "Ironport Savings & Loan",
			MinSquadSize = 2,
			MaxSquadSize = 4,
			BreachSeconds = 12,
			HeistTimeLimitSeconds = 240,
			CooldownSeconds = 600,
			LootBagCount = 4,
			LootBagValueMin = 800,
			LootBagValueMax = 1400,
			HeatOnBreach = 15,
			HeatPerLootBag = 5,
		},
		DockyardArmoredDepot = {
			DisplayName = "Dockyard Armored Depot",
			MinSquadSize = 3,
			MaxSquadSize = 6,
			BreachSeconds = 20,
			HeistTimeLimitSeconds = 300,
			CooldownSeconds = 900,
			LootBagCount = 6,
			LootBagValueMin = 1200,
			LootBagValueMax = 2200,
			HeatOnBreach = 25,
			HeatPerLootBag = 8,
		},
	},
}

return HeistConfig
