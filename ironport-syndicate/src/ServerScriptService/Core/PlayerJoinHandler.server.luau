--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local Persistence = require(script.Parent:WaitForChild("Persistence"))
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
end)

Players.PlayerRemoving:Connect(function(player)
	Persistence.save(player)
	PlayerState.release(player)
end)

game:BindToClose(function()
	for _, player in Players:GetPlayers() do
		Persistence.save(player)
	end
end)
