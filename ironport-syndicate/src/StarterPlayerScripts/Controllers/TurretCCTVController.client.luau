--!strict
-- Manual turret control. Press F near a turret to take its camera; aim with
-- the mouse or right stick; fire with the same trigger as your own weapon;
-- press X (or B on a gamepad) to climb back out.
--
-- This is meant to feel like ARK's manual turret takeover, not like driving a
-- vehicle: movement is locked and the camera is pinned to the gun while
-- active. Look direction is tracked as yaw/pitch rather than read off
-- mouse.Hit, because mouse.Hit is itself derived from the camera's current
-- CFrame — and this script is what's setting that CFrame every frame, so
-- reading aim from the value it's about to overwrite would be circular.
--
-- Access goes through a ProximityPrompt (TurretCCTVPrompt, added by
-- TurretService) exactly like restocking does, but unlike restocking the
-- server side isn't connected to the prompt's Triggered event directly: the
-- client needs a reply carrying starting ammo to render, which a prompt fired
-- server-side has nowhere to send back. So the flow here is: prompt fires
-- locally -> this script calls RequestCCTVAccessRemote itself -> the reply is
-- what actually opens the camera.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local CombatInputLock = require(script.Parent:WaitForChild("CombatInputLock"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Re-fetched rather than cached: CombatController does the same, because
-- CurrentCamera is not guaranteed to be the same Instance for the whole
-- session (a respawn or another script can swap it), and a stale reference
-- here would leave the player driving a camera nobody's looking through.
local function currentCamera(): Camera
	return Workspace.CurrentCamera :: Camera
end

local remotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("TurretCCTVRemotes")
local requestAccessRemote = remotes:WaitForChild("RequestCCTVAccessRemote") :: RemoteFunction
local exitRemote = remotes:WaitForChild("ExitCCTVRemote") :: RemoteEvent
local aimRemote = remotes:WaitForChild("ManualTurretAimRemote") :: RemoteEvent
local fireRemote = remotes:WaitForChild("ManualTurretFireRemote") :: RemoteFunction

local FIRE_ACTION = "IronportTurretFire"
local EXIT_ACTION = "IronportTurretExit"
local FIRE_PRIORITY = 3000 -- above CombatController's default-priority bind
local AIM_SEND_INTERVAL_SECONDS = 0.05
local MOUSE_SENSITIVITY = 0.004
local STICK_RADIANS_PER_SECOND = 2.4
local MAX_PITCH = math.rad(75)
local CAMERA_BACK_OFFSET = 1.5 -- studs behind the anchor, so it's not INSIDE the gun's own hit box

local PANEL = Color3.fromRGB(28, 26, 22)
local LINE = Color3.fromRGB(62, 56, 45)
local TEXT = Color3.fromRGB(236, 229, 214)
local TEXT_DIM = Color3.fromRGB(150, 141, 126)
local BRASS = Color3.fromRGB(198, 150, 74)

type Session = {
	Model: Model,
	Anchor: BasePart,
	Yaw: number,
	Pitch: number,
	LastAimSentAt: number,
	StickInput: Vector2,
	SavedWalkSpeed: number,
	SavedJumpPower: number,
	SavedCameraType: Enum.CameraType,
	SavedCameraSubject: Instance?,
	SavedMouseBehavior: Enum.MouseBehavior,
	SavedMouseIconEnabled: boolean,
	Gui: ScreenGui,
	RoundsLabel: TextLabel,
	ReserveLabel: TextLabel,
	Connections: { RBXScriptConnection },
}

local session: Session? = nil

-- Why access was refused, in words worth reading. Anything not listed here
-- (a stale/destroyed turret, a malformed request) just fails quietly — those
-- aren't decisions a player made, so there's nothing for them to act on.
local ACCESS_DENIED_REASONS: { [string]: string } = {
	NotYourTurret = "Not your turret.",
	AlreadyOccupied = "Someone else is already at the controls.",
	TurretSuppressed = "Over the area's turret limit — it's offline.",
	TooFarAway = "Too far away.",
	PlayerUnavailable = "You can't do that right now.",
}

local function notify(text: string)
	local ok = pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = "Turret",
			Text = text,
			Duration = 3,
		})
	end)
	if not ok then
		-- SendCore can throw if StarterGui hasn't finished initialising yet;
		-- missing one notification isn't worth erroring the whole script over.
		warn("TurretCCTVController: failed to send notification: " .. text)
	end
end

local function buildHud(): (ScreenGui, TextLabel, TextLabel)
	local gui = Instance.new("ScreenGui")
	gui.Name = "TurretCCTVHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true

	local crosshair = Instance.new("Frame")
	crosshair.Name = "Crosshair"
	crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
	crosshair.Position = UDim2.fromScale(0.5, 0.5)
	crosshair.Size = UDim2.fromOffset(8, 8)
	crosshair.Rotation = 45
	crosshair.BackgroundColor3 = BRASS
	crosshair.BorderSizePixel = 0
	crosshair.Parent = gui

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -28)
	panel.Size = UDim2.fromOffset(300, 66)
	panel.BackgroundColor3 = PANEL
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = LINE
	stroke.Thickness = 1
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(14, 6)
	title.Size = UDim2.new(1, -28, 0, 18)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = TEXT_DIM
	title.Text = "MANUAL CONTROL  —  PRESS X TO EXIT"
	title.Parent = panel

	local rounds = Instance.new("TextLabel")
	rounds.Name = "Rounds"
	rounds.BackgroundTransparency = 1
	rounds.Position = UDim2.fromOffset(14, 26)
	rounds.Size = UDim2.new(0.55, -14, 0, 30)
	rounds.Font = Enum.Font.GothamBold
	rounds.TextSize = 24
	rounds.TextXAlignment = Enum.TextXAlignment.Left
	rounds.TextColor3 = TEXT
	rounds.Text = "—"
	rounds.Parent = panel

	local reserve = Instance.new("TextLabel")
	reserve.Name = "Reserve"
	reserve.BackgroundTransparency = 1
	reserve.Position = UDim2.new(0.55, 0, 0, 30)
	reserve.Size = UDim2.new(0.45, -14, 0, 22)
	reserve.Font = Enum.Font.Gotham
	reserve.TextSize = 15
	reserve.TextXAlignment = Enum.TextXAlignment.Right
	reserve.TextColor3 = TEXT_DIM
	reserve.Text = "—"
	reserve.Parent = panel

	gui.Parent = playerGui
	return gui, rounds, reserve
end

local function updateHudFromAttributes(current: Session)
	current.RoundsLabel.Text = tostring(current.Model:GetAttribute("RoundsInMagazine") or "—")
	local reserve = current.Model:GetAttribute("ReserveMagazines")
	current.ReserveLabel.Text = if typeof(reserve) == "number" then ("%d in reserve"):format(reserve) else "—"
end

local function cleanupSession()
	local current = session
	if not current then
		return
	end
	session = nil

	for _, connection in current.Connections do
		connection:Disconnect()
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = current.SavedWalkSpeed
		humanoid.JumpPower = current.SavedJumpPower
	end

	local camera = currentCamera()
	camera.CameraType = current.SavedCameraType
	if current.SavedCameraSubject then
		camera.CameraSubject = current.SavedCameraSubject
	end

	UserInputService.MouseBehavior = current.SavedMouseBehavior
	UserInputService.MouseIconEnabled = current.SavedMouseIconEnabled

	CombatInputLock.locked = false
	ContextActionService:UnbindAction(FIRE_ACTION)
	ContextActionService:UnbindAction(EXIT_ACTION)

	current.Gui:Destroy()
end

-- Voluntary exit: tell the server, then clean up locally. Forced exits arrive
-- the other way — the server already cleared its side, so only the local
-- cleanup runs (see exitRemote.OnClientEvent below).
local function requestExit()
	local current = session
	if not current then
		return
	end
	exitRemote:FireServer(current.Model)
	cleanupSession()
end

local function onExitAction(_actionName: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		requestExit()
	end
	return Enum.ContextActionResult.Sink
end

local function onFireAction(_actionName: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	local current = session
	if not current then
		return Enum.ContextActionResult.Pass
	end
	fireRemote:InvokeServer(current.Model)
	return Enum.ContextActionResult.Sink
end

local function enterManualControl(model: Model, anchor: BasePart)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local gui, roundsLabel, reserveLabel = buildHud()
	local camera = currentCamera()

	local current: Session = {
		Model = model,
		Anchor = anchor,
		Yaw = 0,
		Pitch = 0,
		LastAimSentAt = 0,
		StickInput = Vector2.zero,
		SavedWalkSpeed = humanoid.WalkSpeed,
		SavedJumpPower = humanoid.JumpPower,
		SavedCameraType = camera.CameraType,
		SavedCameraSubject = camera.CameraSubject,
		SavedMouseBehavior = UserInputService.MouseBehavior,
		SavedMouseIconEnabled = UserInputService.MouseIconEnabled,
		Gui = gui,
		RoundsLabel = roundsLabel,
		ReserveLabel = reserveLabel,
		Connections = {},
	}
	session = current

	-- Start looking the way the gun already faces rather than snapping to a
	-- fixed direction, so control begins wherever the model happens to point.
	local startLook = anchor.CFrame.LookVector
	current.Pitch = math.asin(math.clamp(startLook.Y, -1, 1))
	current.Yaw = math.atan2(-startLook.X, -startLook.Z)

	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0

	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	UserInputService.MouseIconEnabled = false

	updateHudFromAttributes(current)

	table.insert(
		current.Connections,
		model:GetAttributeChangedSignal("RoundsInMagazine"):Connect(function()
			updateHudFromAttributes(current)
		end)
	)
	table.insert(
		current.Connections,
		model:GetAttributeChangedSignal("ReserveMagazines"):Connect(function()
			updateHudFromAttributes(current)
		end)
	)

	table.insert(
		current.Connections,
		UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				current.Yaw -= input.Delta.X * MOUSE_SENSITIVITY
				current.Pitch = math.clamp(current.Pitch - input.Delta.Y * MOUSE_SENSITIVITY, -MAX_PITCH, MAX_PITCH)
			elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
				current.StickInput = Vector2.new(input.Position.X, input.Position.Y)
			end
		end)
	)
	table.insert(
		current.Connections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.KeyCode == Enum.KeyCode.Thumbstick2 then
				current.StickInput = Vector2.zero
			end
		end)
	)

	table.insert(
		current.Connections,
		RunService.RenderStepped:Connect(function(dt: number)
			if current.StickInput.Magnitude > 0.15 then
				current.Yaw -= current.StickInput.X * STICK_RADIANS_PER_SECOND * dt
				current.Pitch =
					math.clamp(current.Pitch + current.StickInput.Y * STICK_RADIANS_PER_SECOND * dt, -MAX_PITCH, MAX_PITCH)
			end

			local lookCFrame = CFrame.Angles(0, current.Yaw, 0) * CFrame.Angles(current.Pitch, 0, 0)
			local eyePosition = current.Anchor.Position - lookCFrame.LookVector * CAMERA_BACK_OFFSET
			currentCamera().CFrame = CFrame.new(eyePosition) * lookCFrame

			local now = os.clock()
			if now - current.LastAimSentAt >= AIM_SEND_INTERVAL_SECONDS then
				current.LastAimSentAt = now
				aimRemote:FireServer(current.Model, lookCFrame.LookVector)
			end
		end)
	)

	CombatInputLock.locked = true
	ContextActionService:BindActionAtPriority(
		EXIT_ACTION,
		onExitAction,
		true,
		FIRE_PRIORITY,
		Enum.KeyCode.X,
		Enum.KeyCode.ButtonB
	)
	ContextActionService:BindActionAtPriority(
		FIRE_ACTION,
		onFireAction,
		true,
		FIRE_PRIORITY,
		Enum.UserInputType.MouseButton1,
		Enum.KeyCode.ButtonR2
	)
	ContextActionService:SetTitle(EXIT_ACTION, "Exit")
	ContextActionService:SetTitle(FIRE_ACTION, "Fire")
end

local function onPromptTriggered(prompt: ProximityPrompt, triggeringPlayer: Player)
	if triggeringPlayer ~= player or prompt.Name ~= "TurretCCTVPrompt" then
		return
	end
	if session then
		return -- already in one; the prompt shouldn't even be reachable mid-session
	end

	local anchor = prompt.Parent :: BasePart?
	local model = anchor and anchor.Parent
	if not anchor or not model or not model:IsA("Model") then
		return
	end

	local ok, reason = requestAccessRemote:InvokeServer(model)
	if not ok then
		local message = ACCESS_DENIED_REASONS[reason]
		if message then
			notify(message)
		end
		return
	end
	enterManualControl(model, anchor)
end

ProximityPromptService.PromptTriggered:Connect(onPromptTriggered)

-- What TurretService.ManualControlEnded's `reason` means to the player who
-- got dropped out. PlayerLeft is deliberately absent: nobody's there to read it.
local FORCE_EXIT_REASONS: { [string]: string } = {
	TurretDestroyed = "The turret was destroyed.",
	TurretRemoved = "The turret is gone.",
	TurretSuppressed = "Over the area's turret limit — it's offline.",
	OccupantDown = "Control lost.",
}

-- Forced exit: the server already cleared its side (turret destroyed,
-- suppressed, or this player went down), so only the local half runs — no
-- ExitCCTVRemote:FireServer call back, or the server would just see a
-- request to release a turret this player no longer controls.
exitRemote.OnClientEvent:Connect(function(model: Model, reason: string)
	if session and session.Model == model then
		cleanupSession()
		local message = FORCE_EXIT_REASONS[reason]
		if message then
			notify(message)
		end
	end
end)

-- Safety net for a character that vanishes faster than the server's own
-- tick notices (e.g. leaving the game outright): don't leave the camera
-- pinned to a turret with nobody there to see it.
player.CharacterRemoving:Connect(function()
	if session then
		cleanupSession()
	end
end)
