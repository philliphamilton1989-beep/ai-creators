--!strict
-- Game passes and developer products.
--
-- Ids live here rather than inline in a LocalScript so the server can validate
-- against the same list the client prompts from. Every Id is 0 until the real
-- one is pasted in from the Creator Hub; prompts refuse on 0 rather than failing
-- in the player's face.
--
-- Standing rule, from the GDD's monetization section: a purchase may sell
-- convenience, never a way out of a risk the game just imposed. Everything here
-- is bought in advance and consumed later. Nothing is ever prompted BY the event
-- it protects against — a purchase dialog triggered by your own death is loss
-- framing under time pressure aimed at a mostly underage audience, and it is the
-- one pattern this file exists to keep out.

export type GamePassDefinition = {
	Id: number,
	DisplayName: string,
	Description: string,
	PriceRobux: number,
}

export type ProductDefinition = {
	Id: number,
	DisplayName: string,
	Description: string,
	PriceRobux: number,
	-- What granting it does. Handled in ReceiptService.
	Grant: string,
	GrantAmount: number,
}

local Passes: { [string]: GamePassDefinition } = {
	Backpack = {
		Id = 0,
		DisplayName = "Reinforced Backpack",
		Description = "Doubles how much gear you can carry. Does not affect heist loot.",
		PriceRobux = 400,
	},
}

local Products: { [string]: ProductDefinition } = {
	DeathSave = {
		Id = 0,
		DisplayName = "Death Save",
		Description = "Keep your carried gear the next time you go down. Consumed on use.",
		PriceRobux = 240,
		Grant = "DeathSaveCharge",
		GrantAmount = 1,
	},

	RaidShield24h = {
		Id = 0,
		DisplayName = "24-Hour Shield",
		Description = "Your safehouse can't be raided for 24 hours. Lapses if you raid someone.",
		PriceRobux = 160,
		Grant = "RaidShieldHours",
		GrantAmount = 24,
	},

	EmergencyWarp = {
		Id = 0,
		DisplayName = "Emergency Warp",
		Description = "Escape to a safe point. Unusable for a short time after taking fire.",
		PriceRobux = 80,
		Grant = "WarpCharge",
		GrantAmount = 1,
	},

	CashSmall = {
		Id = 0,
		DisplayName = "Cash Drop",
		Description = "A wire transfer of clean money.",
		PriceRobux = 350,
		Grant = "CleanCash",
		GrantAmount = 50000,
	},

	CashMedium = {
		Id = 0,
		DisplayName = "Cash Bundle",
		Description = "A larger clean transfer.",
		PriceRobux = 900,
		Grant = "CleanCash",
		GrantAmount = 150000,
	},

	CashLarge = {
		Id = 0,
		DisplayName = "Cash Crate",
		Description = "A serious injection of clean capital.",
		PriceRobux = 2500,
		Grant = "CleanCash",
		GrantAmount = 500000,
	},
}

return {
	Passes = Passes,
	Products = Products,

	BackpackCarryMultiplier = 2,
	OwnershipRecheckSeconds = 300,

	-- A warp is an escape route, not a way to win a fight you're losing. Taking
	-- fire locks it out for this long, so it can't be used to vanish mid-exchange
	-- while carrying loot someone else is contesting.
	WarpCombatLockoutSeconds = 12,
}
