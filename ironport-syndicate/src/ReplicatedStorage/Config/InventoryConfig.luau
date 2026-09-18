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
	-- Anti-armor. The launcher is heavy and the rounds are heavier: carrying the
	-- counter to a 3000 HP vehicle costs 15 lb plus 9 lb a rocket, so a crew that
	-- brings one brings less of everything else. That weight IS the balance.
	RPGLauncher = { DisplayName = "RPG Launcher", Weight = 15, Value = 4000, MaxStack = 1, Category = "Weapon" },
	RocketRound = { DisplayName = "Rocket", Weight = 9, Value = 900, MaxStack = 4, Category = "Kit" },

	-- Job kit.
	Medkit = { DisplayName = "Medkit", Weight = 5, Value = 150, MaxStack = 4, Category = "Kit" },
	BreachingCharge = { DisplayName = "Breaching Charge", Weight = 4, Value = 200, MaxStack = 4, Category = "Kit" },
	Lockpick = { DisplayName = "Lockpick", Weight = 1, Value = 40, MaxStack = 10, Category = "Kit" },
	AmmoBox = { DisplayName = "Ammo Box", Weight = 15, Value = 120, MaxStack = 8, Category = "Kit" },
	-- Generator fuel. Heavy on purpose: keeping a turret line powered is a
	-- hauling commitment, not a one-off purchase.
	FuelCan = { DisplayName = "Fuel Can", Weight = 18, Value = 140, MaxStack = 6, Category = "Kit" },

	-- Cargo. Heavy and bulk-priced: this is what a vehicle is for.
	ScrapMetal = { DisplayName = "Scrap Metal", Weight = 12, Value = 60, MaxStack = 40, Category = "Cargo" },
	CopperWire = { DisplayName = "Copper Wire", Weight = 8, Value = 90, MaxStack = 40, Category = "Cargo" },
	CopperPipe = { DisplayName = "Copper Pipe", Weight = 10, Value = 120, MaxStack = 30, Category = "Cargo" },
	CargoCrate = { DisplayName = "Cargo Crate", Weight = 45, Value = 400, MaxStack = 20, Category = "Cargo" },

	-- ZONE 1 — street and dumpster scraps, 15 to 150. Curbside bags, alley
	-- dumpsters, storm drains. Worth taking, never worth a trip.
	BrokenRadio = { DisplayName = "Broken Radio", Weight = 4, Value = 35, MaxStack = 20, Category = "Valuable" },
	BrokenToy = { DisplayName = "Broken Toy", Weight = 2, Value = 15, MaxStack = 20, Category = "Valuable" },
	PlasticToy = { DisplayName = "Toy Figure", Weight = 1, Value = 25, MaxStack = 20, Category = "Valuable" },
	BurnerPhone = { DisplayName = "Burner Phone", Weight = 1, Value = 60, MaxStack = 15, Category = "Valuable" },
	Pocketknife = { DisplayName = "Tarnished Pocketknife", Weight = 1, Value = 45, MaxStack = 15, Category = "Valuable" },
	CopperScrap = { DisplayName = "Copper Scrap", Weight = 12, Value = 70, MaxStack = 30, Category = "Valuable" },

	-- ZONE 2 — hidden stashes and rooftops, 200 to 750. Behind roof vents,
	-- locked fire-escape landings, under cracked floorboards. Electronics carry
	-- real money but badly; jewellery is where the density is.
	Smartwatch = { DisplayName = "Smartwatch", Weight = 1, Value = 260, MaxStack = 10, Category = "Valuable" },
	PowerTools = { DisplayName = "Power Tools", Weight = 14, Value = 300, MaxStack = 10, Category = "Valuable" },
	DesignerSunglasses = { DisplayName = "Designer Sunglasses", Weight = 1, Value = 340, MaxStack = 10, Category = "Valuable" },
	DSLRCamera = { DisplayName = "DSLR Camera", Weight = 4, Value = 420, MaxStack = 10, Category = "Valuable" },
	GameConsole = { DisplayName = "Game Console", Weight = 8, Value = 450, MaxStack = 10, Category = "Valuable" },
	GoldChain = { DisplayName = "Gold Chain", Weight = 1, Value = 600, MaxStack = 10, Category = "Valuable" },
	FlatscreenTV = { DisplayName = "Flatscreen TV", Weight = 28, Value = 700, MaxStack = 6, Category = "Valuable" },

	-- ZONE 3 — black market and high-risk vaults, 1000 and up. Combination
	-- safes, guarded bank storage, boss hideouts. A silver ingot is the whole
	-- weight system in one item: 1800 that you cannot simply pocket and walk.
	EncryptedDrive = { DisplayName = "Encrypted USB Drive", Weight = 1, Value = 1200, MaxStack = 8, Category = "Valuable" },
	SilverIngot = { DisplayName = "Pure Silver Ingot", Weight = 18, Value = 1800, MaxStack = 12, Category = "Valuable" },
	GoldRolex = { DisplayName = "Solid Gold Watch", Weight = 1, Value = 2400, MaxStack = 8, Category = "Valuable" },
	PrototypeMicrochip = { DisplayName = "Prototype Microchip", Weight = 1, Value = 5000, MaxStack = 5, Category = "Valuable" },
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
