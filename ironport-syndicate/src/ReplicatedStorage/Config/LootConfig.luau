--!strict
-- Weighted loot tables.
--
-- Weight is relative, not a percentage: an entry of 30 against a table totalling
-- 100 comes up roughly 30% of the time. Keeping them relative means adding an
-- entry doesn't require rebalancing every other number in the table.
--
-- The tables are shaped around the hauling loop. Industrial sites pay in heavy
-- Cargo, which a player can't carry much of (45 lb a crate against a 250 lb
-- limit), so a vehicle turns four trips into one. Armories pay in gear, which is
-- light and doesn't need hauling at all. That contrast is the point.

export type LootEntry = {
	ItemId: string,
	Weight: number,
	MinCount: number,
	MaxCount: number,
}

export type LootTable = {
	DisplayName: string,
	-- How many draws one search makes. Each draw picks one entry.
	RollsMin: number,
	RollsMax: number,
	Entries: { LootEntry },
}

local Tables: { [string]: LootTable } = {
	-- Street-level scavenging: the trickle that keeps a broke player moving.
	ScavengeCommon = {
		DisplayName = "Scrap Pile",
		RollsMin = 1,
		RollsMax = 3,
		Entries = {
			{ ItemId = "ScrapMetal", Weight = 40, MinCount = 1, MaxCount = 3 },
			{ ItemId = "CopperWire", Weight = 30, MinCount = 1, MaxCount = 3 },
			{ ItemId = "Lockpick", Weight = 20, MinCount = 1, MaxCount = 2 },
			{ ItemId = "Medkit", Weight = 10, MinCount = 1, MaxCount = 1 },
		},
	},

	-- Yards and warehouses: heavy, valuable, and the reason to bring a van.
	ScavengeIndustrial = {
		DisplayName = "Freight Container",
		RollsMin = 2,
		RollsMax = 4,
		Entries = {
			{ ItemId = "CargoCrate", Weight = 35, MinCount = 1, MaxCount = 2 },
			{ ItemId = "ScrapMetal", Weight = 30, MinCount = 2, MaxCount = 5 },
			{ ItemId = "CopperWire", Weight = 20, MinCount = 2, MaxCount = 4 },
			{ ItemId = "AmmoBox", Weight = 15, MinCount = 1, MaxCount = 2 },
		},
	},

	-- Guarded caches. Gear rather than cargo: light, and worth fighting over.
	ScavengeArmory = {
		DisplayName = "Weapons Cache",
		RollsMin = 1,
		RollsMax = 2,
		Entries = {
			{ ItemId = "Sidearm", Weight = 30, MinCount = 1, MaxCount = 1 },
			{ ItemId = "SubmachineGun", Weight = 22, MinCount = 1, MaxCount = 1 },
			{ ItemId = "Shotgun", Weight = 18, MinCount = 1, MaxCount = 1 },
			{ ItemId = "Rifle", Weight = 12, MinCount = 1, MaxCount = 1 },
			{ ItemId = "MachineGun", Weight = 5, MinCount = 1, MaxCount = 1 },
			{ ItemId = "AmmoBox", Weight = 13, MinCount = 1, MaxCount = 2 },
		},
	},

	-- ZONE 1 — street and dumpster scraps. Curbside bags, alley dumpsters, storm
	-- drains. Mostly junk on purpose: it gives a broke player something to sell
	-- without making the open street competitive with the places worth the risk.
	-- Maps to the West Row Houses alleys on the district plan.
	Zone1Street = {
		DisplayName = "Street Scrap",
		RollsMin = 1,
		RollsMax = 3,
		Entries = {
			{ ItemId = "BrokenToy", Weight = 24, MinCount = 1, MaxCount = 2 },
			{ ItemId = "PlasticToy", Weight = 20, MinCount = 1, MaxCount = 2 },
			{ ItemId = "BrokenRadio", Weight = 18, MinCount = 1, MaxCount = 2 },
			{ ItemId = "Pocketknife", Weight = 14, MinCount = 1, MaxCount = 1 },
			{ ItemId = "BurnerPhone", Weight = 14, MinCount = 1, MaxCount = 2 },
			{ ItemId = "CopperScrap", Weight = 10, MinCount = 1, MaxCount = 3 },
		},
	},

	-- ZONE 2 — hidden stashes and rooftops. Behind roof vents, locked fire-escape
	-- landings, under cracked basement floorboards. Real money, and heavy enough
	-- that clearing a stash is a decision about what to leave behind.
	-- Maps to the Rail Scrap Yard and the L station rooftops.
	Zone2Stash = {
		DisplayName = "Hidden Stash",
		RollsMin = 1,
		RollsMax = 3,
		Entries = {
			{ ItemId = "Smartwatch", Weight = 22, MinCount = 1, MaxCount = 2 },
			{ ItemId = "DesignerSunglasses", Weight = 18, MinCount = 1, MaxCount = 2 },
			{ ItemId = "DSLRCamera", Weight = 17, MinCount = 1, MaxCount = 1 },
			{ ItemId = "PowerTools", Weight = 15, MinCount = 1, MaxCount = 1 },
			{ ItemId = "GameConsole", Weight = 13, MinCount = 1, MaxCount = 1 },
			{ ItemId = "GoldChain", Weight = 10, MinCount = 1, MaxCount = 1 },
			{ ItemId = "FlatscreenTV", Weight = 5, MinCount = 1, MaxCount = 1 },
		},
	},

	-- ZONE 3 — black market and high-risk vaults. Combination-locked safes,
	-- guarded bank storage, boss hideouts. The best money in the game, and the
	-- only place a single item is worth more than a full load of Zone 1.
	-- Maps to the Industrial Warehouse (keycard) and the Pawn Exchange boss area.
	Zone3Vault = {
		DisplayName = "Vault Cache",
		RollsMin = 1,
		RollsMax = 2,
		Entries = {
			{ ItemId = "EncryptedDrive", Weight = 30, MinCount = 1, MaxCount = 2 },
			{ ItemId = "SilverIngot", Weight = 26, MinCount = 1, MaxCount = 2 },
			{ ItemId = "GoldRolex", Weight = 24, MinCount = 1, MaxCount = 1 },
			{ ItemId = "PrototypeMicrochip", Weight = 8, MinCount = 1, MaxCount = 1 },
		},
	},

	-- Rolled alongside the cash in a heist loot bag, so a vault pays in kit as
	-- well as money.
	HeistVaultGear = {
		DisplayName = "Vault Contents",
		RollsMin = 1,
		RollsMax = 2,
		Entries = {
			{ ItemId = "CargoCrate", Weight = 28, MinCount = 1, MaxCount = 1 },
			{ ItemId = "BreachingCharge", Weight = 24, MinCount = 1, MaxCount = 2 },
			{ ItemId = "Medkit", Weight = 20, MinCount = 1, MaxCount = 2 },
			{ ItemId = "AmmoBox", Weight = 16, MinCount = 1, MaxCount = 2 },
			{ ItemId = "Rifle", Weight = 12, MinCount = 1, MaxCount = 1 },
		},
	},
}

return {
	Tables = Tables,

	-- How long an emptied container takes to restock. Long enough that camping
	-- one spot is worse than walking a route.
	ContainerRefreshSeconds = 240,

	-- Chance a heist loot bag also rolls gear, on top of its cash value.
	HeistGearChance = 0.35,
}
