--!strict
-- Places where weapons don't work.
--
-- Pawn shops are the reason this exists. Fencing is the one thing every player
-- must do, at a fixed and publicly known location, while carrying the most
-- valuable load they will ever have. Without protection the optimal strategy is
-- to ignore the entire loot game and camp the till — which turns the economy's
-- cash-out step into a kill box and makes every other system pointless.
--
-- The combat tag is what stops the zone being abused from the other direction.
-- Without it, a losing fight is won by sprinting to the nearest shop and
-- becoming invulnerable mid-exchange. Recent combat means the zone doesn't
-- protect you yet: it's a place to do business, not a base to duck into.

return {
	-- Radius around each protected point.
	RadiusStuds = 60,

	-- Time since a player last dealt OR took damage before a safe zone will
	-- protect them. Applies to the aggressor as much as the victim, so a chaser
	-- can't follow someone in and keep shooting either.
	CombatTagSeconds = 10,

	-- Pawn shops are protected automatically. Level design can mark any other
	-- spot by putting a part under Workspace.SafeZones — spawn areas and
	-- vendor rows are the obvious candidates.
	ProtectedFolders = {
		"PawnShops",
		"SafeZones",
	},
}
