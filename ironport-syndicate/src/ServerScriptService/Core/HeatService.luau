--!strict
-- Heat rises from crimes and decays over time. The original scaffold only had
-- code that raised Heat (on gunfire) with nothing bringing it back down, making
-- it a one-way ratchet instead of a manageable resource.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerState = require(script.Parent:WaitForChild("PlayerState"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GameConfig"))

local HeatService = {}

function HeatService.add(player: Player, amount: number)
	local state = PlayerState.get(player)
	if not state then
		return
	end
	state.Heat = math.clamp(state.Heat + amount, 0, GameConfig.Heat.MaxHeat)
	PlayerState.pushOwnerView(player)
end

function HeatService.get(player: Player): number
	local state = PlayerState.get(player)
	return state and state.Heat or 0
end

-- A safehouse (or any other "laying low" zone) calls this on enter/exit to
-- speed up decay while the player is inside it.
function HeatService.setInSafehouse(player: Player, inSafehouse: boolean)
	local state = PlayerState.get(player)
	if not state then
		return
	end
	state.InSafehouse = inSafehouse
end

task.spawn(function()
	while true do
		task.wait(1)
		for _, player in Players:GetPlayers() do
			local state = PlayerState.get(player)
			if state and state.Heat > 0 then
				local rate = state.InSafehouse and GameConfig.Heat.DecayPerSecondInSafehouse
					or GameConfig.Heat.DecayPerSecondIdle
				state.Heat = math.max(0, state.Heat - rate)
				PlayerState.pushOwnerView(player)
			end
		end
	end
end)

return HeatService
