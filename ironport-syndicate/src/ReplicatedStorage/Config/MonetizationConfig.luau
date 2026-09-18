--!strict
-- Game pass definitions. Ids live here rather than inline in a LocalScript so
-- the server can check ownership against the same list the client prompts from.
--
-- Deliberate boundary, per the GDD's monetization rules: a pass may sell
-- convenience, never economic power. The Backpack raises how much GEAR a player
-- can carry into a job. It does not raise heist payout, because heist loot is
-- excluded from carry weight — otherwise this pass would literally be "pay
-- Robux, extract more cash per run".

export type GamePassDefinition = {
	Id: number,
	DisplayName: string,
	Description: string,
	PriceRobux: number,
}

local Passes: { [string]: GamePassDefinition } = {
	Backpack = {
		-- Placeholder. Replace with the real PassId from the published pass's
		-- URL; 0 makes PromptGamePassPurchase fail rather than open a dialog.
		Id = 0,
		DisplayName = "Reinforced Backpack",
		Description = "Doubles how much gear you can carry. Does not affect heist loot.",
		PriceRobux = 400,
	},
}

return {
	Passes = Passes,

	-- How much the Backpack multiplies gear carry capacity by.
	BackpackCarryMultiplier = 2,

	-- Ownership is cached per session. A re-check is cheap on join and on a
	-- completed purchase; polling UserOwnsGamePassAsync is not.
	OwnershipRecheckSeconds = 300,
}
