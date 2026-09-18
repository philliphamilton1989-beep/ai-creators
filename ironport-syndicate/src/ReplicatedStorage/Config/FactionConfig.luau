--!strict
-- Crew (faction) and territory tuning. Pure data so client roster/map UI can
-- read display names, rank thresholds and income rates directly.
--
-- "Crew" is the player-facing term for what the original spec called a gang —
-- see the content-safety pass in the GDD.
--
-- Setting: the city is IRONPORT, fictional. The first playable neighbourhood is
-- the SOUTH ASHLAND DISTRICT. The city stays fictional deliberately — a real
-- city plus organised crime is the branding that risks a 17+ content rating and
-- puts the game out of reach of most of Roblox's audience. District and street
-- names can be as grounded as they like; the city cannot.

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

-- The seven holdable areas of the South Ashland District, the first
-- neighbourhood of Ironport. Ids match the district plan exactly, so level
-- design places a TerritoryNode of the same name and the two stay in step.
--
-- Tuned to what each place IS rather than on a single rising curve. The bridges
-- are cheap chokepoints — fast to take, poor income, but they gate vehicle
-- movement across the canal. The Pawn Exchange pays most and is hardest to hold,
-- because multiple entrances means a crew can take it and still not keep it.
local Territory: { [string]: TerritoryNode } = {
	-- Tight alleys, close quarters, high ambush risk. Small blocks change hands
	-- quickly and pay little.
	WestRowHouses = {
		DisplayName = "West Row Houses",
		IncomePerMinute = 110,
		VendorTier = 1,
		CaptureSeconds = 75,
	},

	-- Drawbridge with sniper overwatch. Holding it is about denying the crossing,
	-- not the money.
	NorthBridge = {
		DisplayName = "North Bridge",
		IncomePerMinute = 90,
		VendorTier = 1,
		CaptureSeconds = 60,
	},

	-- Drawbridge and vehicle blockade: the other half of the canal crossing.
	SouthBridge = {
		DisplayName = "South Bridge",
		IncomePerMinute = 90,
		VendorTier = 1,
		CaptureSeconds = 60,
	},

	-- Elevated platform, quick transit, heavy foot traffic. Exposed to hold.
	AshlandStation = {
		DisplayName = "Ashland L Station",
		IncomePerMinute = 180,
		VendorTier = 2,
		CaptureSeconds = 120,
	},

	-- Heavy cover and industrial hazards. Good income and genuinely defensible.
	RailScrapYard = {
		DisplayName = "Rail Scrap Yard",
		IncomePerMinute = 240,
		VendorTier = 2,
		CaptureSeconds = 150,
	},

	-- Keycard access, high-value storage. Slow to take, pays well, easy to
	-- defend once the door is yours.
	IndustrialWarehouse = {
		DisplayName = "Industrial Warehouse",
		IncomePerMinute = 330,
		VendorTier = 3,
		CaptureSeconds = 200,
	},

	-- The prize at the centre of the district. Best income, longest capture, and
	-- multiple entrances mean taking it is the easy part.
	PawnExchange = {
		DisplayName = "Pawn Exchange District",
		IncomePerMinute = 420,
		VendorTier = 3,
		CaptureSeconds = 230,
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
