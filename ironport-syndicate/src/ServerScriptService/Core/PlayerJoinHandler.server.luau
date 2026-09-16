--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local Persistence = require(script.Parent:WaitForChild("Persistence"))
local FactionService = require(script.Parent.Parent:WaitForChild("Factions"):WaitForChild("FactionService"))
local VehicleService = require(script.Parent.Parent:WaitForChild("Vehicles"):WaitForChild("VehicleService"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GameConfig"))

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

game:BindToClose(function()
	for _, player in Players:GetPlayers() do
		Persistence.save(player)
	end
end)
