--!strict
-- Central damage + downed/bleedout state machine. Required explicitly by
-- whatever needs it (FireWeaponHandler today, vehicle/explosive damage later)
-- instead of being reached through `_G`.
--
-- Also resolves the bleedout timer, which the original scaffold left open:
-- going down fired a 45-second countdown to clients but nothing on the server
-- ever acted on it, so an un-revived player would sit downed forever.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerState = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerState"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GameConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local bleedoutEvent = remotes:WaitForChild("CombatRemotes"):WaitForChild("BleedoutStateRemote") :: RemoteEvent

local DamageService = {}

local bleedoutTimers: { [Player]: thread } = {}

local function forceDeath(player: Player)
	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")

	local state = PlayerState.get(player)
	if state then
		-- Going down and not getting picked up in time costs half your Street
		-- Cash. That's the game's real death penalty, not a full-loot wipe.
		state.StreetCash = math.floor(state.StreetCash * 0.5)
		state.IsDowned = false
		PlayerState.pushOwnerView(player)
	end

	bleedoutTimers[player] = nil

	if humanoid then
		humanoid.Health = 0
	end
end

local function beginBleedout(player: Player, humanoid: Humanoid)
	local state = PlayerState.get(player)
	if not state then
		return
	end

	state.IsDowned = true
	humanoid.Health = math.max(humanoid.Health, 1)
	humanoid.WalkSpeed = GameConfig.Bleedout.CrawlSpeed
	humanoid.PlatformStand = true

	bleedoutEvent:FireAllClients(player, true, GameConfig.Bleedout.DurationSeconds)

	local existing = bleedoutTimers[player]
	if existing then
		task.cancel(existing)
	end

	bleedoutTimers[player] = task.delay(GameConfig.Bleedout.DurationSeconds, function()
		local liveState = PlayerState.get(player)
		if liveState and liveState.IsDowned then
			forceDeath(player)
		end
	end)
end

-- Called by RevivePlayerRemote / FinishDownedPlayerRemote handlers to resolve
-- a downed player one way or the other before the timer expires.
function DamageService.resolveBleedout(player: Player, humanoid: Humanoid, revived: boolean)
	local timer = bleedoutTimers[player]
	if timer then
		task.cancel(timer)
		bleedoutTimers[player] = nil
	end

	local state = PlayerState.get(player)
	if state then
		state.IsDowned = false
	end

	humanoid.PlatformStand = false
	humanoid.WalkSpeed = 16

	if revived then
		humanoid.Health = math.max(humanoid.Health, humanoid.MaxHealth * 0.4)
		bleedoutEvent:FireAllClients(player, false, 0)
	else
		forceDeath(player)
		bleedoutEvent:FireAllClients(player, false, 0)
	end
end

-- Returns true if the target died outright (no bleedout state applies — e.g. an NPC).
function DamageService.processDamage(targetHumanoid: Humanoid, damage: number, attacker: Player?, isHeadshot: boolean): boolean
	local char = targetHumanoid.Parent
	if not char then
		return false
	end

	local player = Players:GetPlayerFromCharacter(char)
	if not player then
		targetHumanoid:TakeDamage(damage)
		return targetHumanoid.Health <= 0
	end

	local state = PlayerState.get(player)
	if not state then
		return false
	end

	if state.IsDowned then
		targetHumanoid.Health -= damage
		if targetHumanoid.Health <= 0 then
			forceDeath(player)
			return true
		end
		return false
	end

	if targetHumanoid.Health - damage <= 0 then
		beginBleedout(player, targetHumanoid)
		return false
	end

	targetHumanoid.Health -= damage
	return false
end

return DamageService
