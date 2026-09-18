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
local SafeZoneService = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("SafeZoneService"))
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

-- Armored cover is published as attributes on the character by VehicleService
-- when a player takes a seat. Read here rather than required, because
-- VehicleService already depends on this module and the reverse would be a
-- cycle — an attribute crosses that boundary with no dependency at all.
--
-- Full immunity to small arms would make an armored vehicle a rolling gun
-- platform with no answer, so a heavy or precise hit penetrates the glass at
-- reduced damage. Explosives ignore cover entirely; they're the intended
-- counter.
local function applyArmoredCover(character: Instance, damage: number, damageType: string): number
	if damageType ~= "Ballistic" then
		return damage
	end

	local multiplier = character:GetAttribute("CoverBallisticMultiplier")
	if typeof(multiplier) ~= "number" then
		return damage
	end

	local penetrationDamage = character:GetAttribute("CoverPenetrationDamage")
	if typeof(penetrationDamage) == "number" and damage >= penetrationDamage then
		local penetrationMultiplier = character:GetAttribute("CoverPenetrationMultiplier")
		return damage * (if typeof(penetrationMultiplier) == "number" then penetrationMultiplier else 1)
	end

	return damage * multiplier
end

-- Returns true if the target died outright (no bleedout state applies — e.g. an NPC).
function DamageService.processDamage(
	targetHumanoid: Humanoid,
	damage: number,
	attacker: Player?,
	isHeadshot: boolean,
	damageType: string?
): boolean
	local character = targetHumanoid.Parent
	if not character then
		return false
	end

	damage = applyArmoredCover(character, damage, damageType or "Ballistic")
	if damage <= 0 then
		return false -- fully absorbed by armor
	end

	-- Safe zones cut both ways: a protected target can't be shot, and a
	-- protected attacker can't shoot out. Checked before anything is stamped,
	-- because a blocked shot must leave NO trace. Tagging on a blocked hit would
	-- hand an attacker a way to strip a peaceful player's protection just by
	-- firing at them — griefing the exact people the zone exists to protect.
	local attackerCharacter = attacker and attacker.Character
	if SafeZoneService.isProtected(character :: Model) or SafeZoneService.isProtected(attackerCharacter) then
		return false
	end

	-- Real exchange: both parties are now in combat. Read by the safe-zone
	-- combat tag and the Emergency Warp lockout. Attributes rather than calls,
	-- so neither module has to require the other.
	local now = os.clock()
	character:SetAttribute("LastCombatAt", now)
	if attackerCharacter then
		attackerCharacter:SetAttribute("LastCombatAt", now)
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
