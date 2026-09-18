--!strict
-- Every carryable item: what it weighs (POUNDS) and what it's worth.
--
-- Weights are calibrated against real equipment — a loaded pistol is ~3 lb, a
-- submachine gun ~7, a rifle ~9, a light machine gun ~11 — so the numbers read
-- true to anyone who knows the kit.
--
-- Value is the item's full worth. A pawn shop pays a fraction of it (see
-- PawnConfig), so fencing is always lossy and a better shop is worth walking to.
--
-- The interesting number is neither weight nor value alone, it's VALUE DENSITY.
-- A diamond ring is 1500 in one pound; a flatscreen is 500 in twenty-eight. With
-- a 250 lb limit that is the whole decision: fill your hands with jewellery and
-- walk, or bring the van and clear the room. Items are tuned along that axis on
-- purpose, not just "rare = expensive".

export type ItemDefinition = {
	DisplayName: string,
	-- Pounds.
	Weight: number,
	-- Full worth in cash. Pawn shops pay a fraction.
	Value: number,
	MaxStack: number,
	Category: string,
}

local Items: { [string]: ItemDefinition } = {
	-- Weapons. Roughly true to life, loaded.
	Sidearm = { DisplayName = "Sidearm", Weight = 3, Value = 600, MaxStack = 1, Category = "Weapon" },
	SubmachineGun = { DisplayName = "Submachine Gun", Weight = 7, Value = 1100, MaxStack = 1, Category = "Weapon" },
	Shotgun = { DisplayName = "Shotgun", Weight = 8, Value = 1000, MaxStack = 1, Category = "Weapon" },
	Rifle = { DisplayName = "Rifle", Weight = 9, Value = 1600, MaxStack = 1, Category = "Weapon" },
	MachineGun = { DisplayName = "Machine Gun", Weight = 11, Value = 2200, MaxStack = 1, Category = "Weapon" },

	-- Job kit.
	Medkit = { DisplayName = "Medkit", Weight = 5, Value = 150, MaxStack = 4, Category = "Kit" },
	BreachingCharge = { DisplayName = "Breaching Charge", Weight = 4, Value = 200, MaxStack = 4, Category = "Kit" },
	Lockpick = { DisplayName = "Lockpick", Weight = 1, Value = 40, MaxStack = 10, Category = "Kit" },
	AmmoBox = { DisplayName = "Ammo Box", Weight = 15, Value = 120, MaxStack = 8, Category = "Kit" },

	-- Cargo. Heavy and bulk-priced: this is what a vehicle is for.
	ScrapMetal = { DisplayName = "Scrap Metal", Weight = 12, Value = 60, MaxStack = 40, Category = "Cargo" },
	CopperWire = { DisplayName = "Copper Wire", Weight = 8, Value = 90, MaxStack = 40, Category = "Cargo" },
	CopperPipe = { DisplayName = "Copper Pipe", Weight = 10, Value = 120, MaxStack = 30, Category = "Cargo" },
	CargoCrate = { DisplayName = "Cargo Crate", Weight = 45, Value = 400, MaxStack = 20, Category = "Cargo" },

	-- Valuables, low tier. What a new player finds on the street: worth taking,
	-- not worth a trip.
	BrokenToy = { DisplayName = "Broken Toy", Weight = 2, Value = 15, MaxStack = 20, Category = "Valuable" },
	PlasticToy = { DisplayName = "Toy Figure", Weight = 1, Value = 25, MaxStack = 20, Category = "Valuable" },
	OldPhone = { DisplayName = "Old Phone", Weight = 1, Value = 80, MaxStack = 15, Category = "Valuable" },

	-- Valuables, mid tier. Electronics: decent money, awkward to carry in bulk.
	PowerTools = { DisplayName = "Power Tools", Weight = 14, Value = 300, MaxStack = 10, Category = "Valuable" },
	Laptop = { DisplayName = "Laptop", Weight = 5, Value = 350, MaxStack = 10, Category = "Valuable" },
	GameConsole = { DisplayName = "Game Console", Weight = 8, Value = 420, MaxStack = 10, Category = "Valuable" },
	SilverCandlestick = { DisplayName = "Silver Candlestick", Weight = 4, Value = 450, MaxStack = 10, Category = "Valuable" },
	FlatscreenTV = { DisplayName = "Flatscreen TV", Weight = 28, Value = 500, MaxStack = 6, Category = "Valuable" },

	-- Valuables, top tier. Light and precious: the reason to search the places
	-- nobody walks past.
	AntiqueVase = { DisplayName = "Antique Vase", Weight = 9, Value = 700, MaxStack = 6, Category = "Valuable" },
	GoldWatch = { DisplayName = "Gold Watch", Weight = 1, Value = 900, MaxStack = 10, Category = "Valuable" },
	DiamondRing = { DisplayName = "Diamond Ring", Weight = 1, Value = 1500, MaxStack = 10, Category = "Valuable" },
	BearerBonds = { DisplayName = "Bearer Bonds", Weight = 1, Value = 2400, MaxStack = 5, Category = "Valuable" },
}

return {
	Items = Items,

	-- Pounds a player can carry before the pass multiplier.
	BaseCarryWeight = 250,

	-- Pounds a vehicle can hold.
	VehicleCargoCapacity = 500,

	-- Applied while at or over capacity.
	OverweightWalkSpeed = 8,
	NormalWalkSpeed = 16,
}
