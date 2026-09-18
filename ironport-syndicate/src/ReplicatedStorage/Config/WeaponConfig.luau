--!strict
-- Central weapon stat table. The server validates every client-claimed weaponId
-- against this before trusting any damage/range/fire-rate value — the original
-- scaffold accepted a weaponId but ignored it, dealing flat damage regardless
-- of what was actually equipped.

export type WeaponStats = {
	Damage: number,
	HeadshotMultiplier: number,
	Range: number,
	FireRateSeconds: number, -- minimum seconds between shots, enforced server-side

	-- Projectile weapons launch a simulated round instead of raycasting. Absent
	-- means hitscan, which is every conventional firearm here.
	Projectile: boolean?,
	ProjectileSpeed: number?, -- studs per second
	BlastRadius: number?,
	DamageType: string?, -- defaults to Ballistic
	-- Item consumed per shot. A launcher with no rounds is dead weight, which is
	-- what keeps the hard counter scarce rather than free.
	AmmoItemId: string?,
}

local WeaponConfig: { [string]: WeaponStats } = {
	Sidearm = {
		Damage = 18,
		HeadshotMultiplier = 2,
		Range = 900,
		FireRateSeconds = 0.28,
	},
	SubmachineGun = {
		Damage = 14,
		HeadshotMultiplier = 1.75,
		Range = 700,
		FireRateSeconds = 0.09,
	},
	Shotgun = {
		-- Whole-hit damage, not per-pellet: only one ray is cast. Real pellet
		-- spread needs a spread angle and a multi-ray loop, which isn't built
		-- yet — the damage here stands in for the full spread connecting.
		Damage = 65,
		HeadshotMultiplier = 1.5,
		Range = 250,
		FireRateSeconds = 0.85,
	},
	Rifle = {
		Damage = 26,
		HeadshotMultiplier = 2,
		Range = 1500,
		FireRateSeconds = 0.11,
	},
	MachineGun = {
		-- Sustained fire rather than burst damage; the 11 lb it costs to carry
		-- (see InventoryConfig) is most of what balances it.
		Damage = 16,
		HeadshotMultiplier = 1.5,
		Range = 1100,
		FireRateSeconds = 0.07,
	},

	-- The answer to armor. 1000 raw becomes 2750 against the Raider's 2.75x
	-- HeavyExplosive vulnerability, so two hits end it — which is the contract
	-- the armored vehicle was balanced against.
	--
	-- It is a travel-time projectile on purpose. 2750 damage that could not miss
	-- would make armor unbuyable; a rocket you can see coming and drive away
	-- from makes it a duel. At 90 studs a second a shot across 100 studs takes
	-- over a second to arrive, which is enough time to react and not enough to
	-- stroll away.
	RPG = {
		Damage = 1000,
		HeadshotMultiplier = 1, -- a rocket does not care where it hits you
		Range = 400,
		FireRateSeconds = 3,
		Projectile = true,
		ProjectileSpeed = 90,
		BlastRadius = 15,
		DamageType = "HeavyExplosive",
		AmmoItemId = "RocketRound",
	},
}

return WeaponConfig
