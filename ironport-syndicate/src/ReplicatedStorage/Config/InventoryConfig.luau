--!strict
-- Carry weight, in POUNDS, and the items that count toward it.
--
-- Weights are calibrated against real equipment: a loaded pistol is ~2-3 lb, a
-- submachine gun ~7, a combat shotgun ~8, a rifle ~9, a light machine gun ~11.
-- That keeps the numbers legible to players who know what this kit weighs.
--
-- Consequence worth knowing: at a 250 lb limit, guns barely constrain anyone —
-- a realistic two-gun loadout with kit is about 30 lb. The limit is there for
-- HAULING. Crates, scrap and ammo are what actually fill it, which is why a
-- vehicle (500 lb) is the difference between one trip and four.
--
-- What is NOT here matters as much as what is: heist loot bags and Street Cash
-- carry no weight, which is what stops the Backpack pass from being a
-- purchasable payout increase. See MonetizationConfig.

export type ItemDefinition = {
	DisplayName: string,
	-- Pounds.
	Weight: number,
	MaxStack: number,
	Category: string,
}

local Items: { [string]: ItemDefinition } = {
	-- Weapons. Roughly true to life, loaded.
	Sidearm = { DisplayName = "Sidearm", Weight = 3, MaxStack = 1, Category = "Weapon" },
	SubmachineGun = { DisplayName = "Submachine Gun", Weight = 7, MaxStack = 1, Category = "Weapon" },
	Shotgun = { DisplayName = "Shotgun", Weight = 8, MaxStack = 1, Category = "Weapon" },
	Rifle = { DisplayName = "Rifle", Weight = 9, MaxStack = 1, Category = "Weapon" },
	MachineGun = { DisplayName = "Machine Gun", Weight = 11, MaxStack = 1, Category = "Weapon" },

	-- Job kit.
	Medkit = { DisplayName = "Medkit", Weight = 5, MaxStack = 4, Category = "Kit" },
	BreachingCharge = { DisplayName = "Breaching Charge", Weight = 4, MaxStack = 4, Category = "Kit" },
	Lockpick = { DisplayName = "Lockpick", Weight = 1, MaxStack = 10, Category = "Kit" },
	AmmoBox = { DisplayName = "Ammo Box", Weight = 15, MaxStack = 8, Category = "Kit" },

	-- Cargo. Heavy on purpose: this is what makes the limits bite and what makes
	-- a vehicle worth bringing.
	ScrapMetal = { DisplayName = "Scrap Metal", Weight = 12, MaxStack = 40, Category = "Cargo" },
	CopperWire = { DisplayName = "Copper Wire", Weight = 8, MaxStack = 40, Category = "Cargo" },
	CargoCrate = { DisplayName = "Cargo Crate", Weight = 45, MaxStack = 20, Category = "Cargo" },
}

return {
	Items = Items,

	-- Pounds a player can carry before the pass multiplier.
	BaseCarryWeight = 250,

	-- Pounds a vehicle can hold. Uniform across the catalog for now; varying it
	-- per vehicle (a Panel Van over an Interceptor) is the obvious next turn of
	-- the dial.
	VehicleCargoCapacity = 500,

	-- Applied while at or over capacity.
	OverweightWalkSpeed = 8,
	NormalWalkSpeed = 16,
}
