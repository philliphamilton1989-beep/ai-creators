--!strict
-- Crew (faction) and territory tuning. Pure data so client roster/map UI can
-- read display names, rank thresholds and income rates directly.
--
-- "Crew" is the player-facing term for what the original spec called a gang —
-- see the content-safety pass in the GDD.

export type TerritoryNode = {
	DisplayName: string,
	IncomePerMinute: number,
	VendorTier: number,
	CaptureSeconds: number,
}

-- Contribution needed to hold each rank. Boss is deliberately absent: it is
-- held by the crew's founder, or passed on when they leave, not earned by
-- contribution.
local RankLadder: { { Rank: string, Contribution: number } } = {
	{ Rank = "Recruit", Contribution = 0 },
	{ Rank = "Associate", Contribution = 10000 },
	{ Rank = "Enforcer", Contribution = 50000 },
	{ Rank = "Underboss", Contribution = 150000 },
}

-- Starting set of six. The full map targets 12-20 blocks; these exist so the
-- capture and income loops are exercisable before the level is built out.
local Territory: { [string]: TerritoryNode } = {
	StockyardBlocks = {
		DisplayName = "Stockyard Blocks",
		IncomePerMinute = 120,
		VendorTier = 1,
		CaptureSeconds = 90,
	},
	FoundryRow = {
		DisplayName = "Foundry Row",
		IncomePerMinute = 160,
		VendorTier = 1,
		CaptureSeconds = 110,
	},
	CanalDistrict = {
		DisplayName = "Canal District",
		IncomePerMinute = 200,
		VendorTier = 2,
		CaptureSeconds = 130,
	},
	RailYards = {
		DisplayName = "Rail Yards",
		IncomePerMinute = 240,
		VendorTier = 2,
		CaptureSeconds = 150,
	},
	DocksideWharf = {
		DisplayName = "Dockside Wharf",
		IncomePerMinute = 320,
		VendorTier = 3,
		CaptureSeconds = 180,
	},
	BrassQuarter = {
		DisplayName = "Brass Quarter",
		IncomePerMinute = 400,
		VendorTier = 3,
		CaptureSeconds = 210,
	},
}

return {
	CreationCostCleanCash = 25000,
	MaxMembers = 20,
	MinNameLength = 3,
	MaxNameLength = 24,
	InviteExpirySeconds = 120,

	RankLadder = RankLadder,
	Territory = Territory,

	-- Ranks allowed to perform each action. Compared by ladder position, with
	-- Boss above every rung.
	MinRankToInvite = "Enforcer",
	MinRankToKick = "Underboss",

	-- Credited per minute a crew holds a node, split across that crew's online
	-- members, so holding turf counts toward rank rather than cash donations
	-- being the only path up.
	ContributionPerNodeMinute = 250,

	-- How often held territory pays out.
	IncomeIntervalSeconds = 60,

	-- Capture progress lost per second while a node is contested by more than
	-- one crew, or sitting unattended mid-capture.
	ContestedDecayPerSecond = 1.5,
	UnattendedDecayPerSecond = 0.5,
}
