--!strict
-- Carry weight and the items that count toward it.
--
-- What is NOT here matters as much as what is: heist loot bags and Street Cash
-- carry no weight. That's what keeps the Backpack pass from being a purchasable
-- payout increase — see MonetizationConfig.

export type ItemDefinition = {
	DisplayName: string,
	Weight: number,
	MaxStack: number,
}

local Items: { [string]: ItemDefinition } = {
	-- Weapons. Weight is the main reason not to simply carry one of everything.
	Sidearm = { DisplayName = "Sidearm", Weight = 3, MaxStack = 1 },
	SubmachineGun = { DisplayName = "Submachine Gun", Weight = 7, MaxStack = 1 },
	Shotgun = { DisplayName = "Shotgun", Weight = 9, MaxStack = 1 },
	Rifle = { DisplayName = "Rifle", Weight = 11, MaxStack = 1 },

	-- Consumables and job kit.
	Medkit = { DisplayName = "Medkit", Weight = 4, MaxStack = 3 },
	BreachingCharge = { DisplayName = "Breaching Charge", Weight = 6, MaxStack = 2 },
	Lockpick = { DisplayName = "Lockpick", Weight = 1, MaxStack = 5 },
	ScrapMetal = { DisplayName = "Scrap Metal", Weight = 2, MaxStack = 20 },
}

return {
	Items = Items,

	-- Base capacity before any pass multiplier. Tuned so a full loadout is a
	-- real choice: a Rifle plus two Medkits plus a charge is already most of it.
	BaseCarryWeight = 30,

	-- Movement penalty applied while at or over capacity. Going over is possible
	-- only via a capacity drop (losing the pass mid-session), never by picking
	-- something up, so this is a recovery state rather than a normal one.
	OverweightWalkSpeed = 8,
	NormalWalkSpeed = 16,
}
