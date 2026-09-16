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
		Damage = 12, -- per pellet
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
}

return WeaponConfig
