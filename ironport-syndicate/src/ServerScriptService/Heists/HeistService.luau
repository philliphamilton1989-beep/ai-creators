--!strict
-- Squad-based PvE heists: breach a vault door, then loot it before the timer
-- (or the crew) runs out. Reuses PlantBreachingChargeRemote and
-- PickupLootBagRemote, which were already declared in the remote manifest but
-- unimplemented, rather than adding new remotes for the same actions.
--
-- Squad presence is enforced server-side by checking who is actually standing
-- near the vault door when the breach timer finishes — never by trusting a
-- client's claim of who's in the crew. If the level's HeistSites folder
-- doesn't exist yet (this is a code scaffold, no map has been built in Studio
-- yet), proximity checks are skipped with a one-time warning instead of
-- erroring, so the system is testable before the level is.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerState = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("PlayerState"))
local HeatService = require(script.Parent.Parent:WaitForChild("Core"):WaitForChild("HeatService"))
local HeistConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("HeistConfig"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local plantChargeRemote = remotes:WaitForChild("CombatRemotes"):WaitForChild("PlantBreachingChargeRemote") :: RemoteFunction
local pickupLootRemote = remotes:WaitForChild("EconomyRemotes"):WaitForChild("PickupLootBagRemote") :: RemoteFunction
local phaseRemote = remotes:WaitForChild("HeistsRemotes"):WaitForChild("HeistPhaseRemote") :: RemoteEvent

local PROXIMITY_STUDS = 40

type LootBag = {
	Value: number,
	Claimed: boolean,
}

type HeistPhase = "Breaching" | "Looting"

type HeistInstance = {
	SiteId: string,
	Phase: HeistPhase,
	Participants: { [Player]: true },
	LootBags: { [string]: LootBag },
	LootRemaining: number,
	ExpiresAt: number,
}

local HeistService = {}

local activeHeists: { [string]: HeistInstance } = {}
local lastEndedAt: { [string]: number } = {}
local warnedMissingAnchor: { [string]: true } = {}

-- Checked rather than cast: a VaultDoor that isn't a BasePart would throw on
-- .Position deep inside a remote handler instead of failing the lookup cleanly.
local function getSiteAnchor(siteId: string): BasePart?
	local sitesFolder = Workspace:FindFirstChild("HeistSites")
	local siteModel = sitesFolder and sitesFolder:FindFirstChild(siteId)
	local door = siteModel and siteModel:FindFirstChild("VaultDoor")
	if door and door:IsA("BasePart") then
		return door
	end
	return nil
end

local function warnMissingAnchorOnce(siteId: string)
	if warnedMissingAnchor[siteId] then
		return
	end
	warnedMissingAnchor[siteId] = true
	warn(("HeistService: no Workspace.HeistSites.%s.VaultDoor found — skipping proximity checks for this site until it's built"):format(siteId))
end

local function isNearSite(player: Player, siteId: string): boolean
	local anchor = getSiteAnchor(siteId)
	if not anchor then
		warnMissingAnchorOnce(siteId)
		return true
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end
	return (root.Position - anchor.Position).Magnitude <= PROXIMITY_STUDS
end

local function playersNearSite(siteId: string): { Player }
	local anchor = getSiteAnchor(siteId)
	if not anchor then
		warnMissingAnchorOnce(siteId)
		-- Site not built yet: treat everyone currently online as "the crew"
		-- so the state machine is testable before the level exists.
		return Players:GetPlayers()
	end

	local nearby = {}
	for _, player in Players:GetPlayers() do
		if isNearSite(player, siteId) then
			table.insert(nearby, player)
		end
	end
	return nearby
end

local function tableKeys(t: { [string]: any }): { string }
	local keys = {}
	for key in t do
		table.insert(keys, key)
	end
	return keys
end

local function isOnCooldown(siteId: string): boolean
	local config = HeistConfig.Sites[siteId]
	local endedAt = lastEndedAt[siteId]
	if not config or not endedAt then
		return false
	end
	return os.clock() - endedAt < config.CooldownSeconds
end

local function broadcast(siteId: string, phase: string, extra: { [string]: any }?)
	local payload = extra or {}
	payload.SiteId = siteId
	payload.Phase = phase
	phaseRemote:FireAllClients(payload)
end

local function completeBreach(siteId: string)
	local instance = activeHeists[siteId]
	if not instance or instance.Phase ~= "Breaching" then
		return -- already resolved (e.g. cleared by the expiry watchdog)
	end

	local config = HeistConfig.Sites[siteId]
	if not config then
		activeHeists[siteId] = nil
		return
	end

	local crew = playersNearSite(siteId)

	if #crew < config.MinSquadSize then
		activeHeists[siteId] = nil
		lastEndedAt[siteId] = os.clock()
		broadcast(siteId, "Failed", { Reason = "NotEnoughCrew" })
		return
	end

	if #crew > config.MaxSquadSize then
		local capped = {}
		for i = 1, config.MaxSquadSize do
			capped[i] = crew[i]
		end
		crew = capped
	end

	for _, player in crew do
		instance.Participants[player] = true
	end

	local lootBags: { [string]: LootBag } = {}
	for i = 1, config.LootBagCount do
		lootBags[siteId .. "_Bag" .. i] = {
			Value = math.random(config.LootBagValueMin, config.LootBagValueMax),
			Claimed = false,
		}
	end

	instance.Phase = "Looting"
	instance.LootBags = lootBags
	instance.LootRemaining = config.LootBagCount
	instance.ExpiresAt = os.clock() + config.HeistTimeLimitSeconds

	broadcast(siteId, "Looting", {
		ExpiresAt = instance.ExpiresAt,
		LootBagIds = tableKeys(lootBags),
		LootRemaining = instance.LootRemaining,
	})
end

plantChargeRemote.OnServerInvoke = function(player: Player, siteId: string): (boolean, string)
	if typeof(siteId) ~= "string" then
		return false, "InvalidSite"
	end
	local config = HeistConfig.Sites[siteId]
	if not config then
		return false, "UnknownSite"
	end
	if activeHeists[siteId] then
		return false, "AlreadyInProgress"
	end
	if isOnCooldown(siteId) then
		return false, "SiteOnCooldown"
	end

	local state = PlayerState.get(player)
	if not state or state.IsDowned then
		return false, "PlayerUnavailable"
	end
	if not isNearSite(player, siteId) then
		return false, "TooFarFromSite"
	end

	local instance: HeistInstance = {
		SiteId = siteId,
		Phase = "Breaching",
		Participants = {},
		LootBags = {},
		LootRemaining = 0,
		ExpiresAt = os.clock() + config.BreachSeconds,
	}
	activeHeists[siteId] = instance

	broadcast(siteId, "Breaching", { ExpiresAt = instance.ExpiresAt })
	HeatService.add(player, config.HeatOnBreach)

	task.delay(config.BreachSeconds, function()
		completeBreach(siteId)
	end)

	return true, "BreachStarted"
end

pickupLootRemote.OnServerInvoke = function(player: Player, siteId: string, lootBagId: string): (boolean, string)
	if typeof(siteId) ~= "string" or typeof(lootBagId) ~= "string" then
		return false, "InvalidArgs"
	end

	local instance = activeHeists[siteId]
	if not instance or instance.Phase ~= "Looting" then
		return false, "NoActiveLooting"
	end
	if not instance.Participants[player] then
		return false, "NotInCrew"
	end

	local bag = instance.LootBags[lootBagId]
	if not bag then
		return false, "UnknownLootBag"
	end
	if bag.Claimed then
		return false, "AlreadyClaimed"
	end

	local state = PlayerState.get(player)
	if not state then
		return false, "PlayerUnavailable"
	end
	if not isNearSite(player, siteId) then
		return false, "TooFarFromSite"
	end

	bag.Claimed = true
	instance.LootRemaining -= 1

	state.StreetCash += bag.Value
	PlayerState.pushOwnerView(player)
	HeatService.add(player, HeistConfig.Sites[siteId].HeatPerLootBag)

	broadcast(siteId, "Looting", { LootRemaining = instance.LootRemaining, ClaimedBagId = lootBagId })

	if instance.LootRemaining <= 0 then
		activeHeists[siteId] = nil
		lastEndedAt[siteId] = os.clock()
		broadcast(siteId, "Cleared")
	end

	return true, "Claimed"
end

Players.PlayerRemoving:Connect(function(player)
	for _, instance in activeHeists do
		instance.Participants[player] = nil
	end
end)

task.spawn(function()
	while true do
		task.wait(5)
		local now = os.clock()
		for siteId, instance in activeHeists do
			if now >= instance.ExpiresAt then
				activeHeists[siteId] = nil
				lastEndedAt[siteId] = now
				broadcast(siteId, "Expired")
			end
		end
	end
end)

function HeistService.getPhase(siteId: string): HeistPhase?
	local instance = activeHeists[siteId]
	return instance and instance.Phase
end

return HeistService
