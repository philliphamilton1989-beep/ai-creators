--!strict
-- Shared tuning values. Kept as plain data so design numbers can change without
-- touching the systems that consume them.

return {
	StartingCleanCash = 15000,

	Heat = {
		DecayPerSecondIdle = 0.15,
		DecayPerSecondInSafehouse = 0.6,
		MaxHeat = 100,
	},

	Bleedout = {
		DurationSeconds = 45,
		CrawlSpeed = 3,
	},

	Raid = {
		CooldownSeconds = 3 * 60 * 60, -- one raid per safehouse per 3 real hours
		NewPlayerShieldSeconds = 60 * 60, -- 1 hour of playtime before a player is raidable
		InsuredCashFraction = 0.25, -- fraction of Street Cash a raid can never take
	},

	Laundering = {
		CycleSeconds = 90,
		ConversionRate = 0.7, -- Street Cash -> Clean Cash
	},
}
