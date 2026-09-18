--!strict
-- Vehicle catalog and damage tuning. Pure data so garage UI can price and
-- describe vehicles without a remote round-trip.
--
-- Contract with the vehicle prefabs: this service owns health, ownership and
-- the disabled flag. Each prefab's own drive script is responsible for reading
-- the VehicleDisabled attribute off its root model and cutting throttle
-- accordingly — physics stays with the model, authority stays here.

export type VehicleStats = {
	DisplayName: string,
	PurchaseCostCleanCash: number,
	MaxHealth: number,
	RepairCostPerHealth: number,
	RepairSeconds: number,
	SpawnCooldownSeconds: number,
	Seats: number,
	-- Names a profile in ArmoredVehicleConfig. Absent means an ordinary vehicle:
	-- damage lands flat and occupants are not protected.
	ArmorProfile: string?,
}

local Catalog: { [string]: VehicleStats } = {
	Runabout = {
		DisplayName = "Runabout",
		PurchaseCostCleanCash = 0, -- granted free; see StarterVehicleId
		MaxHealth = 350,
		RepairCostPerHealth = 4,
		RepairSeconds = 6,
		SpawnCooldownSeconds = 20,
		Seats = 4,
	},
	PanelVan = {
		DisplayName = "Panel Van",
		PurchaseCostCleanCash = 18000,
		MaxHealth = 600,
		RepairCostPerHealth = 6,
		RepairSeconds = 10,
		SpawnCooldownSeconds = 30,
		Seats = 6,
	},
	Interceptor = {
		DisplayName = "Interceptor",
		PurchaseCostCleanCash = 45000,
		MaxHealth = 400,
		RepairCostPerHealth = 12,
		RepairSeconds = 8,
		SpawnCooldownSeconds = 45,
		Seats = 2,
	},
	ArmoredHauler = {
		DisplayName = "Armored Hauler",
		PurchaseCostCleanCash = 120000,
		MaxHealth = 1400,
		RepairCostPerHealth = 18,
		RepairSeconds = 20,
		SpawnCooldownSeconds = 90,
		Seats = 4,
	},

	-- The raid vehicle: a bullet sponge for walking a crew through defensive
	-- fire, not a win condition. 3000 HP against 60% ballistic resistance is
	-- 500 turret hits at 15 damage a shot; explosives cut through it at 1.5x,
	-- and the long cooldown means losing one costs a raid window, not a minute.
	Raider = {
		DisplayName = "Raider",
		PurchaseCostCleanCash = 285000,
		MaxHealth = 3000,
		RepairCostPerHealth = 22,
		RepairSeconds = 35,
		SpawnCooldownSeconds = 600,
		Seats = 4,
		ArmorProfile = "AssaultArmor",
	},
}

return {
	Catalog = Catalog,

	-- Every player owns this one from their first join, so nobody is ever
	-- stranded without transport.
	StarterVehicleId = "Runabout",

	-- Below this fraction of max health the engine is dead: the prefab's drive
	-- script should refuse throttle while VehicleDisabled is true.
	DisabledHealthFraction = 0.25,

	-- Damage dealt to anyone still seated when the vehicle is destroyed. Routed
	-- through DamageService, so it puts players into bleedout rather than
	-- killing outright.
	DestructionOccupantDamage = 45,

	-- How long the wreck stays before it's cleaned up.
	DespawnAfterDestroyedSeconds = 6,

	-- Range for repairing or interacting with a vehicle on foot.
	InteractRangeStuds = 25,
}
