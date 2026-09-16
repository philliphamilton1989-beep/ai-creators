--!strict
-- Client-side input and a UX-only debounce. The server (FireWeaponHandler)
-- enforces the real fire-rate limit and independently validates every shot —
-- this debounce exists purely so a held mouse button doesn't spam the remote,
-- not as a security measure.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local camera = Workspace.CurrentCamera

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local fireEvent = remotes:WaitForChild("CombatRemotes"):WaitForChild("FireWeaponRemote") :: RemoteEvent

local equippedWeaponId = "Sidearm"
local fireDebounce = false

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end
	if fireDebounce then
		return
	end

	fireDebounce = true
	local origin = camera.CFrame.Position
	local direction = (mouse.Hit.Position - origin).Unit
	fireEvent:FireServer(equippedWeaponId, origin, direction)

	task.delay(0.08, function()
		fireDebounce = false
	end)
end)
