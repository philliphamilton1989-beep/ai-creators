--!strict
-- Armor profiles: how a vehicle converts incoming damage, and what it does as
-- it comes apart.
--
-- Deliberate split from VehicleConfig, which stays the single source of truth
-- for the catalog (health, price, cooldown, seats). Duplicating MaxHealth or
-- PurchasePrice across two files would just raise the question of which one
-- wins. A catalog entry names an ArmorProfile here; this file holds only what
-- is specific to being armored.

export type DamageState = {
	-- Fraction of max health at or below which this state applies.
	Threshold: number,
	Smoke: boolean,
	Fire: boolean,
	-- Drive speed multiplier the prefab's own drive script should honour.
	SpeedMultiplier: number,
}

export type ArmorProfile = {
	DisplayName: string,

	-- Incoming damage is multiplied by these. 0.4 is the 60% ballistic
	-- reduction; explosives are amplified so the counterplay is unambiguous.
	--
	-- HeavyExplosive (rockets, missiles, C4) is deliberately a separate class
	-- from Explosive (frags, minor area effects). A grenade should chip an
	-- armored chassis; a missile should end the conversation. One multiplier
	-- cannot do both jobs.
	Multipliers: { [string]: number },

	-- Occupant protection while the vehicle is intact.
	--
	-- A flat zero would make this a rolling gun platform with no answer, which
	-- is the godmode case. The penetration threshold is the release valve: a
	-- heavy or precise shot (a shotgun at close range, a headshot from a rifle)
	-- comes through the glass at reduced damage. Light automatic fire does not.
	OccupantBallisticMultiplier: number,
	WindowPenetrationDamage: number,
	WindowPenetrationMultiplier: number,

	-- Ordered most-damaged first; the first matching threshold wins.
	DamageStates: { DamageState },

	-- Dealt to anyone still aboard when it goes up.
	DestructionOccupantDamageMin: number,
	DestructionOccupantDamageMax: number,
}

local Profiles: { [string]: ArmorProfile } = {
	AssaultArmor = {
		DisplayName = "Assault Armor",

		Multipliers = {
			Ballistic = 0.4, -- 60% reduction: a 15-damage turret shot lands 6
			Explosive = 1.5, -- frags and satchels: chips armor, doesn't defeat it
			-- 2.75 is not a rounded-off guess. Against 3000 HP a 1000-damage
			-- rocket lands 2750, leaving 8.3% — inside the "critical burning
			-- below 15%" requirement, with two hits guaranteeing destruction.
			-- At 2.5 the first hit leaves 16.7% and misses that bar; at 3.0 a
			-- single rocket destroys a full-health chassis outright and the
			-- two-hit guarantee stops meaning anything. The band that satisfies
			-- every requirement at once is [2.55, 3.0), and this sits in it.
			HeavyExplosive = 2.75,
			Melee = 0.25, -- fists and bats are not a way through armor plate
		},

		OccupantBallisticMultiplier = 0,
		WindowPenetrationDamage = 40,
		WindowPenetrationMultiplier = 0.5,

		DamageStates = {
			{ Threshold = 0.25, Smoke = true, Fire = true, SpeedMultiplier = 0.65 },
			{ Threshold = 0.50, Smoke = true, Fire = false, SpeedMultiplier = 1 },
		},

		DestructionOccupantDamageMin = 30,
		DestructionOccupantDamageMax = 50,
	},
}

return {
	Profiles = Profiles,

	-- Damage with no type named is treated as ballistic: it's the overwhelming
	-- majority of incoming fire, and defaulting to the resisted type is the
	-- forgiving direction to be wrong in.
	DefaultDamageType = "Ballistic",

	-- Types that count as explosive for occupant bleed-through and splash.
	ExplosiveDamageTypes = {
		Explosive = true,
		HeavyExplosive = true,
	},

	-- Types that count as ordnance: these bypass ragdoll ejection on a kill.
	HeavyDamageTypes = {
		HeavyExplosive = true,
	},

	Blast = {
		-- Near misses inside this radius still wreck wheels and treads.
		SplashRadiusStuds = 15,
		SplashDamageFraction = 0.5,
		-- Strips half of whatever speed the vehicle had left, briefly. Layered
		-- over the damage-state multiplier rather than replacing it, so a near
		-- miss on an already-burning vehicle compounds instead of healing it.
		SplashSpeedFraction = 0.5,
		SplashSpeedDurationSeconds = 4,
		-- Fraction of RAW explosive damage passed to occupants. Measured on raw
		-- rather than resolved: resolved is amplified by armor vulnerability,
		-- and it would be perverse for better armor to kill its own crew harder.
		OccupantBleedFraction = 0.3,
	},

	CriticalFailure = {
		-- Resolved damage in a single instance. Resolved, not raw: this is about
		-- the magnitude of the blow that actually landed on the chassis.
		DamageThreshold = 1500,
		SpeedMultiplier = 0.3, -- a 70% penalty
		DisableReverse = true,
	},

	-- Clearance a vehicle needs at a spawn point before it will use it, so a
	-- 3000 HP wedge doesn't materialise inside a wall.
	SpawnClearancePadding = 2,
}
