--!strict
-- Central damage and the downed/bleedout state machine. Required explicitly by
-- whatever needs it (FireWeaponHandler, VehicleService, explosives later)
-- instead of being reached through `_G`.
--
-- The downed state is authoritative here and mirrored nowhere else: IsDowned on
-- PlayerState is the single source of truth, and BleedoutStateRemote is how
-- clients learn about it. Every path out of downed — revived, finished, or the
-- timer expiring — has to clear that flag and tell the clients, or a player
-- comes back from respawn permanently unable to act.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerState = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerState"))
local GameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GameConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local bleedoutEvent = remotes:WaitForChild("CombatRemotes"):WaitForChild("BleedoutStateRemote") :: RemoteEvent

local DEFAULT_WALK_SPEED = 16

local DamageService = {}

local bleedoutTimers: { [Player]: thread } = {}

local function cancelTimer(player: Player)
	local timer = bleedoutTimers[player]
	if timer then
		task.cancel(timer)
		bleedoutTimers[player] = nil
	end
end

local function isAlive(humanoid: Humanoid): boolean
	return humanoid.Health > 0 and humanoid:GetState() ~= Enum.HumanoidStateType.Dead
end

local function forceDeath(player: Player)
	cancelTimer(player)

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	local state = PlayerState.get(player)
	if state then
		-- Going down and not getting picked up in time costs half your Street
		-- Cash. That's the game's real death penalty, not a full-loot wipe.
		state.StreetCash = math.floor(state.StreetCash * 0.5)
		state.IsDowned = false
		PlayerState.pushOwnerView(player)
	end

	-- Clients have a downed indicator up; it has to come down on this path too,
	-- not just on revive.
	bleedoutEvent:FireAllClients(player, false, 0)

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
	-- Pinned at a fixed low value rather than floored at whatever health
	-- happened to be left. Passive regen is suppressed project-wide (see
	-- StarterCharacterScripts/Health), so this stays where it's put.
	humanoid.Health = GameConfig.Bleedout.DownedHealth
	humanoid.WalkSpeed = GameConfig.Bleedout.CrawlSpeed
	humanoid.PlatformStand = true

	bleedoutEvent:FireAllClients(player, true, GameConfig.Bleedout.DurationSeconds)

	cancelTimer(player)
	bleedoutTimers[player] = task.delay(GameConfig.Bleedout.DurationSeconds, function()
		local liveState = PlayerState.get(player)
		if liveState and liveState.IsDowned then
			forceDeath(player)
		end
	end)
end

function DamageService.isDowned(player: Player): boolean
	local state = PlayerState.get(player)
	return state ~= nil and state.IsDowned
end

-- Resolves a downed player one way or the other before the timer expires.
-- Called by the RevivePlayerRemote / FinishDownedPlayerRemote handlers.
function DamageService.resolveBleedout(player: Player, humanoid: Humanoid, revived: boolean)
	cancelTimer(player)

	if not revived then
		forceDeath(player)
		return
	end

	local state = PlayerState.get(player)
	if state then
		state.IsDowned = false
	end

	humanoid.PlatformStand = false
	humanoid.WalkSpeed = DEFAULT_WALK_SPEED
	humanoid.Health = math.max(humanoid.Health, humanoid.MaxHealth * 0.4)

	bleedoutEvent:FireAllClients(player, false, 0)
end

-- Returns true if the target died outright (no bleedout state applies — e.g. an NPC).
function DamageService.processDamage(targetHumanoid: Humanoid, damage: number, attacker: Player?, isHeadshot: boolean): boolean
	local character = targetHumanoid.Parent
	if not character then
		return false
	end

	-- Never act on a corpse. Without this, shooting a body during the respawn
	-- window puts the already-dead player into bleedout, which leaves IsDowned
	-- stuck true on their next life and halves their cash when the timer fires.
	if not isAlive(targetHumanoid) then
		return false
	end

	local player = Players:GetPlayerFromCharacter(character)
	if not player then
		targetHumanoid:TakeDamage(damage)
		return targetHumanoid.Health <= 0
	end

	local state = PlayerState.get(player)
	if not state then
		return false
	end

	if state.IsDowned then
		-- TakeDamage rather than assigning Health, so ForceField spawn
		-- protection is respected on this path as well as the NPC one.
		targetHumanoid:TakeDamage(damage)
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

	targetHumanoid:TakeDamage(damage)
	return false
end

-- A new character is a clean slate: clear any downed state left over from the
-- previous life, including deaths that happened outside this service.
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		cancelTimer(player)
		local state = PlayerState.get(player)
		if state and state.IsDowned then
			state.IsDowned = false
			PlayerState.pushOwnerView(player)
			bleedoutEvent:FireAllClients(player, false, 0)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	cancelTimer(player)
end)

return DamageService
