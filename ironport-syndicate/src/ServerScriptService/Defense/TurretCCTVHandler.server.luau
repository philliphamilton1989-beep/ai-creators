--!strict
-- Owns the TurretCCTVRemotes: RequestCCTVAccessRemote, ExitCCTVRemote,
-- ManualTurretAimRemote, ManualTurretFireRemote.
--
-- RequestCCTVAccessRemote and ManualTurretFireRemote are RemoteFunctions
-- because the client needs a reply — starting ammo to render a HUD from, and
-- a hit/miss result for feedback — that a fire-and-forget event can't carry.
-- ManualTurretAimRemote is the opposite: aim updates dozens of times a second
-- while someone looks around, nothing about the previous update matters once
-- a new one lands, and a reply nobody's waiting on would just be wasted
-- round trips. It's a RemoteEvent.
--
-- ExitCCTVRemote runs both directions on one instance: the client fires it to
-- leave voluntarily, and the server fires it back at a specific client when
-- TurretService ends their control without being asked (turret destroyed,
-- suppressed, or the player went down) — the same shape FireWeaponHandler and
-- friends assume elsewhere in this codebase (one remote, direction decided by
-- who's connecting which event).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TurretService = require(script.Parent:WaitForChild("TurretService"))
local Numeric = require(ReplicatedStorage:WaitForChild("Libraries"):WaitForChild("Numeric"))

local remotes = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("TurretCCTVRemotes")
local requestAccessRemote = remotes:WaitForChild("RequestCCTVAccessRemote") :: RemoteFunction
local exitRemote = remotes:WaitForChild("ExitCCTVRemote") :: RemoteEvent
local aimRemote = remotes:WaitForChild("ManualTurretAimRemote") :: RemoteEvent
local fireRemote = remotes:WaitForChild("ManualTurretFireRemote") :: RemoteFunction

-- Every payload here names a turret by Instance rather than trusting an
-- id/path string, so this is the only shape-check any of the four handlers
-- need: a live Model, not whatever else a client might send.
local function asTurretModel(value: unknown): Model?
	if typeof(value) == "Instance" and value:IsA("Model") then
		return value
	end
	return nil
end

requestAccessRemote.OnServerInvoke = function(player: Player, model: unknown): (boolean, string)
	local turretModel = asTurretModel(model)
	if not turretModel then
		return false, "InvalidTurret"
	end
	return TurretService.beginManualControl(player, turretModel)
end

exitRemote.OnServerEvent:Connect(function(player: Player, model: unknown)
	local turretModel = asTurretModel(model)
	if not turretModel then
		return
	end
	TurretService.endManualControl(player, turretModel)
end)

aimRemote.OnServerEvent:Connect(function(player: Player, model: unknown, direction: unknown)
	local turretModel = asTurretModel(model)
	if not turretModel then
		return
	end
	if typeof(direction) ~= "Vector3" or not Numeric.isFiniteVector(direction) then
		return
	end
	TurretService.setManualAim(player, turretModel, direction)
end)

fireRemote.OnServerInvoke = function(player: Player, model: unknown): (boolean, string)
	local turretModel = asTurretModel(model)
	if not turretModel then
		return false, "InvalidTurret"
	end
	return TurretService.manualFire(player, turretModel)
end

-- Forced exits originate deep in TurretService, which has no business
-- reaching into ReplicatedStorage for a remote — that wiring belongs here.
TurretService.ManualControlEnded:Connect(function(player: Player, model: Model, reason: string)
	if player.Parent then
		exitRemote:FireClient(player, model, reason)
	end
end)
