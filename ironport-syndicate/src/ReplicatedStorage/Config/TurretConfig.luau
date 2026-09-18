--!strict
-- Automated defensive turrets, modelled on ARK's.
--
-- There is one turret. ARK ships a Heavy tier alongside the standard one, but
-- its job there is to give a big base a reason to spend its turret budget
-- differently — and that only pays off once players have been building for
-- weeks. A second tier bought here would be a second set of numbers to balance
-- against the Raider, the RPG and each other, for a choice nobody is equipped
-- to make yet. One gun, tuned properly, is the honest version.
--
-- What's worth copying from ARK isn't the damage numbers, it's the three rules
-- that stop turrets becoming an unbeatable wall. Any one of them missing and
-- defense degenerates:
--
--  1. A DENSITY CAP. Without a limit on turrets per area, the winning move is
--     always "add another turret", and a well-funded crew becomes unraidable by
--     arithmetic rather than skill.
--  2. POWER. A turret line that needs a generator gives raiders something to
--     attack other than the guns themselves. Without it the only counterplay is
--     grinding through the ammo, which is a timer rather than a tactic. With it,
--     a smart raid pushes for the generator and the whole line goes dark.
--  3. TARGETING MODES. Defenders decide what their guns engage, so a turret
--     covering a driveway isn't wasting its drum on someone walking past.
--
-- The 15 damage is a contract with the Raider: 15 against a 0.4 ballistic
-- multiplier is 6 net, so 3000 HP takes exactly 500 hits, which is the "2-3
-- magazines to breach" the armored vehicle was designed around. Change one and
-- you change the other.

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
	-- Drawn from the generator while online.
	PowerDraw: number,
}

-- Still a table rather than a bare set of fields: a turret carries a TurretTier
-- attribute naming its entry, so a second gun is a new entry here plus a
-- weighted cost in the density cap, and nothing in TurretService changes.
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
		PowerDraw = 1,
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
	DefaultTier = "Standard",
	TargetModes = TargetModes,
	DefaultTargetMode = "Everything",

	-- With one gun the cap is simply a count: at most this many turrets inside
	-- the radius, and the rest sit inert. Tuned for a 1.2 km district — a
	-- safehouse can be genuinely well defended, but not walled off. Twelve guns
	-- all bearing on one approach is 288 net DPS against the Raider's armor,
	-- which kills it in about ten seconds of full exposure: survivable if the
	-- driver keeps moving and uses cover, fatal if they park.
	--
	-- Turrets past the cap stay inert rather than being refused, so a level or a
	-- player can't get into a state where a placed turret silently doesn't exist.
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
