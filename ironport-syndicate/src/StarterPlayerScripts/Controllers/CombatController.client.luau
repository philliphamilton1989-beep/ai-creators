--!strict
-- Firing input. Bound through ContextActionService rather than a raw
-- MouseButton1 listener so gamepad players get a trigger and mobile players get
-- a generated on-screen button — the previous mouse-only binding left the
-- majority of Roblox's audience unable to shoot at all.
--
-- The client sends only an aim direction. Which weapon is firing, where the shot
-- starts and how fast it may be fired are all server-held (see
-- FireWeaponHandler), so the local debounce here is purely to avoid spamming
-- the remote while the trigger is held — not a security measure.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CombatInputLock = require(script.Parent:WaitForChild("CombatInputLock"))

local player = Players.LocalPlayer
local mouse = player:GetMouse()

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local fireEvent = remotes:WaitForChild("CombatRemotes"):WaitForChild("FireWeaponRemote") :: RemoteEvent

local FIRE_ACTION = "IronportFire"
local SEND_INTERVAL_SECONDS = 0.05

local lastSentAt = 0

-- The server raycasts from the character's head, so aim is measured from there
-- too; deriving it from the camera instead would send a direction that doesn't
-- match the ray the server actually casts.
local function aimDirection(): Vector3?
	local character = player.Character
	local head = character and character:FindFirstChild("Head") :: BasePart?
	local camera = Workspace.CurrentCamera
	if not head or not camera then
		return nil
	end

	-- mouse.Hit is already a camera-through-cursor raycast. With no pointer
	-- (gamepad, touch) fall back to where the camera is looking.
	local target = mouse.Hit and mouse.Hit.Position or (camera.CFrame.Position + camera.CFrame.LookVector * 500)
	local delta = target - head.Position
	if delta.Magnitude <= 0 then
		return nil
	end
	return delta.Unit
end

local function onFireAction(_actionName: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end

	-- Manually piloting a turret owns the trigger while it's active; without
	-- this, the same click would also discharge the player's own weapon.
	if CombatInputLock.locked then
		return Enum.ContextActionResult.Pass
	end

	local now = os.clock()
	if now - lastSentAt < SEND_INTERVAL_SECONDS then
		return Enum.ContextActionResult.Sink
	end

	local direction = aimDirection()
	if direction then
		lastSentAt = now
		fireEvent:FireServer(direction)
	end

	return Enum.ContextActionResult.Sink
end

ContextActionService:BindAction(
	FIRE_ACTION,
	onFireAction,
	true, -- generate a touch button for mobile
	Enum.UserInputType.MouseButton1,
	Enum.KeyCode.ButtonR2
)
ContextActionService:SetTitle(FIRE_ACTION, "Fire")
