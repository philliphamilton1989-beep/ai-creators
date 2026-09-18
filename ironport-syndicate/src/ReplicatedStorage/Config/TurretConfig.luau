--!strict
-- Automated defensive turrets, modelled on ARK's.
--
-- What's worth copying from ARK isn't the damage numbers, it's the three rules
-- that stop turrets becoming an unbeatable wall. Any one of them missing and
-- defense degenerates:
--
--  1. A DENSITY CAP. Without a limit on turrets per area, the winning move is
--     always "add another turret", and a well-funded crew becomes unraidable by
--     arithmetic rather than skill. ARK caps them per radius, and Heavy turrets
--     count as several — so the cap is a real budget, spent on few strong guns
--     or many weak ones.
--  2. POWER. A turret line that needs a generator gives raiders something to
--     attack other than the guns themselves. Without it the only counterplay is
--     grinding through the ammo, which is a timer rather than a tactic. With it,
--     a smart raid pushes for the generator and the whole line goes dark.
--  3. TARGETING MODES. Defenders decide what their guns engage, so a turret
--     covering a driveway isn't wasting its drum on someone walking past.
--
-- The Standard turret's 15 damage is a contract with the Raider: 15 against a
-- 0.4 ballistic multiplier is 6 net, so 3000 HP takes exactly 500 hits, which
-- is the "2-3 magazines to breach" the armored vehicle was designed around.
-- Change one and you change the other.

export type TurretTier = {
	DisplayName: string,
	Damage: number,
	FireRateSeconds: number,
	RangeStuds: number,
	MagazineSize: number,
	ReserveMagazines: number,
	ReloadSeconds: number,
	AcquisitionSeconds: number,
	Health: number,
	-- How much of the area's turret budget this consumes. Heavy guns cost more
	-- than their firepower advantage, so stacking them is a real decision.
	CapCost: number,
	-- Drawn from the generator while online.
	PowerDraw: number,
}

local Tiers: { [string]: TurretTier } = {
	Standard = {
		DisplayName = "Autoturret",
		Damage = 15,
		FireRateSeconds = 0.25,
		RangeStuds = 180,
		MagazineSize = 200,
		ReserveMagazines = 3,
		ReloadSeconds = 4,
		AcquisitionSeconds = 0.6,
		Health = 800,
		CapCost = 1,
		PowerDraw = 1,
	},

	-- Costs four slots, so it has to be worth four Standards or nobody would
	-- ever build one. Deliberately tuned to near-parity on damage (250 dps
	-- against their 240) and differentiated on everything else:
	--
	--   better  — 260 range against 180, and one hard target instead of four
	--             soft ones
	--   worse   — 360 rounds against 3200, so it runs dry in about a quarter
	--             the time and demands constant restocking
	--
	-- A wall of Standards is a siege you grind down. A Heavy line hits harder
	-- and further but has to be fed, which is what makes the choice interesting
	-- rather than arithmetic.
	Heavy = {
		DisplayName = "Heavy Autoturret",
		Damage = 55,
		FireRateSeconds = 0.22,
		RangeStuds = 260,
		MagazineSize = 120,
		ReserveMagazines = 2,
		ReloadSeconds = 7,
		AcquisitionSeconds = 1,
		Health = 2200,
		CapCost = 4,
		PowerDraw = 4,
	},
}

-- What a turret is allowed to shoot at. Set per turret with a TargetMode
-- attribute; anything unrecognised falls back to Everything.
local TargetModes: { [string]: { Players: boolean, Vehicles: boolean } } = {
	Everything = { Players = true, Vehicles = true },
	PlayersOnly = { Players = true, Vehicles = false },
	VehiclesOnly = { Players = false, Vehicles = true },
}

return {
	Tiers = Tiers,
	TargetModes = TargetModes,
	DefaultTargetMode = "Everything",

	-- The budget, and the area it applies over. Tuned for a 1.2 km district: a
	-- safehouse can be genuinely well defended, but not walled off. Turrets past
	-- the cap stay inert rather than being refused, so a level or a player can't
	-- get into a state where a placed turret silently doesn't exist.
	DensityCap = 12,
	DensityRadiusStuds = 140,

	-- Vehicles are shot before people. A turret plinking at infantry while an
	-- armored vehicle parks on its doorstep would never burn the ammo the raid
	-- economy depends on.
	PreferVehicleTargets = true,

	-- One AmmoBox refills one magazine, which puts defense on the same
	-- carry-weight economy as everything else: holding a turret line means
	-- hauling 15 lb a magazine to it.
	RoundsPerAmmoBox = 1,
	RestockRangeStuds = 12,

	-- Turrets ignore downed players. Finishing someone is a decision another
	-- player makes; a turret grinding a body is just noise.
	IgnoreDownedTargets = true,

	Power = {
		-- How far a generator reaches. Smaller than turret range on purpose:
		-- the generator sits inside the perimeter it powers, which is what makes
		-- pushing to it a real objective.
		GeneratorRadiusStuds = 120,
		-- Fuel burned per second per unit of draw.
		FuelPerPowerSecond = 0.02,
		-- One FuelCan is worth this much fuel.
		FuelPerCan = 300,
		MaxFuel = 1200,
		RefuelRangeStuds = 12,
		GeneratorHealth = 1200,
	},
}
