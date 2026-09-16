--!strict
local Players = game:GetService("Players")

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local Persistence = require(script.Parent:WaitForChild("Persistence"))
local FactionService = require(script.Parent.Parent:WaitForChild("Factions"):WaitForChild("FactionService"))
local VehicleService = require(script.Parent.Parent:WaitForChild("Vehicles"):WaitForChild("VehicleService"))

-- BindToClose gets a limited window from Roblox; leave headroom rather than
-- spending all of it waiting on stragglers.
local SHUTDOWN_SAVE_DEADLINE_SECONDS = 20

-- Matches FactionService's flush cadence. Without it, player data only reached
-- the DataStore on leave, so a hard crash (where BindToClose never runs) lost
-- the whole session — and worse, crew donations flushed on a timer while the
-- Clean Cash that paid for them did not, which duplicates money across the crew
-- boundary on a crash.
local AUTOSAVE_INTERVAL_SECONDS = 60

Players.PlayerAdded:Connect(function(player)
	local saved = Persistence.load(player)

	-- Persistence.load yields, potentially for seconds of retry backoff. If the
	-- player left during it, PlayerRemoving has already run its release, and
	-- carrying on here would re-populate the state table afterwards — leaking an
	-- entry and a strong Player reference for the life of the server, and doing
	-- a crew read and a starter-vehicle grant for someone who is gone.
	if not player:IsDescendantOf(Players) then
		return
	end

	-- PlayerState owns the balance and creates the leaderstats mirror itself, so
	-- there's no window where one exists without the other.
	PlayerState.init(player, saved)

	-- Called explicitly rather than from FactionService's own PlayerAdded
	-- connection: crew state can only be resolved once PlayerState exists, and
	-- connection ordering between two scripts isn't guaranteed.
	FactionService.onPlayerReady(player)
	VehicleService.onPlayerReady(player)
end)

Players.PlayerRemoving:Connect(function(player)
	-- The player's own save goes first: the crew flush can yield for seconds of
	-- DataStore retry backoff, and on shutdown that delay could cost them their
	-- save entirely. The only real constraint is that the crew flush happens
	-- before PlayerState.release, since it reads their crew out of it.
	Persistence.save(player)
	FactionService.onPlayerLeaving(player)
	PlayerState.release(player)
end)

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL_SECONDS)
		for _, player in Players:GetPlayers() do
			task.spawn(Persistence.save, player)
		end
	end
end)

-- Saves run in parallel, not serially. Each save can spend seconds in DataStore
-- retries, and Roblox only allows BindToClose a limited window before killing
-- the process. Saving a full server one player at a time would run past that
-- window and lose everyone at the back of the list.
game:BindToClose(function()
	local players = Players:GetPlayers()
	local remaining = #players
	if remaining == 0 then
		return
	end

	for _, player in players do
		task.spawn(function()
			Persistence.save(player)
			remaining -= 1
		end)
	end

	local deadline = os.clock() + SHUTDOWN_SAVE_DEADLINE_SECONDS
	while remaining > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)
