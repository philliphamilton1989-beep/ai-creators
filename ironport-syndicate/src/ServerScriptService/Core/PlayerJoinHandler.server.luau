--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local Persistence = require(script.Parent:WaitForChild("Persistence"))
local FactionService = require(script.Parent.Parent:WaitForChild("Factions"):WaitForChild("FactionService"))
local VehicleService = require(script.Parent.Parent:WaitForChild("Vehicles"):WaitForChild("VehicleService"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GameConfig"))

-- BindToClose gets a limited window from Roblox; leave headroom rather than
-- spending all of it waiting on stragglers.
local SHUTDOWN_SAVE_DEADLINE_SECONDS = 20

Players.PlayerAdded:Connect(function(player)
	local saved = Persistence.load(player)

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local cleanCash = Instance.new("IntValue")
	cleanCash.Name = "Clean Cash"
	cleanCash.Value = (saved and saved.CleanCash) or GameConfig.StartingCleanCash
	cleanCash.Parent = leaderstats

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
