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
			Explosive = 1.5, -- RPGs and charges are the intended counter
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

	-- Clearance a vehicle needs at a spawn point before it will use it, so a
	-- 3000 HP wedge doesn't materialise inside a wall.
	SpawnClearancePadding = 2,
}
