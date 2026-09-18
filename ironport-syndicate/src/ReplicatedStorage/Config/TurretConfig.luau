--!strict
-- Automated defensive turrets.
--
-- The damage number is load-bearing and not arbitrary. 15 per shot against the
-- Raider's 0.4 ballistic multiplier is 6 net, so 3000 HP takes exactly 500 hits
-- — 2.5 drums of 200, which is the "2-3 magazines to breach" the armored
-- vehicle was specified against. Changing either number breaks that contract, so
-- change them together.
--
-- The same 15 kills an unarmored player in under two seconds. That asymmetry is
-- the entire reason the Raider exists: infantry cannot walk a defended approach,
-- armor can. A turret that were merely annoying to infantry would make the
-- vehicle pointless, and one that shredded armor would make it a waste of money.
--
-- Turrets are destructible on purpose. A defense with no counter is a wall, and
-- the raid is supposed to be a fight rather than a timer.

export type TurretTier = {
	DisplayName: string,
	Damage: number,
	FireRateSeconds: number,
	RangeStuds: number,
	-- Rounds per magazine, and how many spare magazines it holds.
	MagazineSize: number,
	ReserveMagazines: number,
	ReloadSeconds: number,
	-- Time locked on a target before the first shot. The window that lets a
	-- player sprint across an exposed gap and live.
	AcquisitionSeconds: number,
	Health: number,
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
	},

	-- Heavier gun, shallower magazine. Better against armor per shot, worse at
	-- sustaining a long siege, so stacking them isn't strictly better.
	Heavy = {
		DisplayName = "Heavy Autoturret",
		Damage = 25,
		FireRateSeconds = 0.45,
		RangeStuds = 220,
		MagazineSize = 120,
		ReserveMagazines = 2,
		ReloadSeconds = 6,
		AcquisitionSeconds = 0.9,
		Health = 1400,
	},
}

return {
	Tiers = Tiers,

	-- Vehicles are shot before people. A turret that kept plinking at infantry
	-- while an armored vehicle parked on its doorstep would never burn the ammo
	-- the raid economy depends on.
	PreferVehicleTargets = true,

	-- One AmmoBox from a player's inventory refills one magazine, which ties
	-- defense to the same carry-weight economy as everything else: restocking a
	-- turret line means hauling 15 lb a magazine.
	RoundsPerAmmoBox = 1,

	-- How close an owner must stand to restock.
	RestockRangeStuds = 12,

	-- Turrets ignore downed players. Finishing someone is a decision another
	-- player makes; a turret grinding a body is just noise.
	IgnoreDownedTargets = true,
}
