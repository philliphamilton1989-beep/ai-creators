--!strict
-- Answers one question: is this character currently protected from violence?
--
-- Deliberately dependency-free — it reads the world and a config and nothing
-- else. That's what lets DamageService require it without a cycle, and it means
-- protection is evaluated at the moment damage is dealt rather than sampled by
-- a polling loop. A poll would leave a window where someone standing in a shop
-- doorway can still be shot because the flag hasn't ticked over yet.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SafeZoneConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("SafeZoneConfig"))

local SafeZoneService = {}

local warnedNoZones = false

local function zoneAnchors(): { BasePart }
	local anchors = {}
	for _, folderName in SafeZoneConfig.ProtectedFolders do
		local folder = Workspace:FindFirstChild(folderName)
		if not folder then
			continue
		end
		for _, child in folder:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(anchors, child)
			elseif child:IsA("Model") then
				local anchor = child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")
				if anchor then
					table.insert(anchors, anchor)
				end
			end
		end
	end
	return anchors
end

-- Stamped by DamageService whenever a character deals or takes damage.
function SafeZoneService.isCombatTagged(character: Instance): boolean
	local lastCombat = character:GetAttribute("LastCombatAt")
	if typeof(lastCombat) ~= "number" then
		return false
	end
	return os.clock() - lastCombat < SafeZoneConfig.CombatTagSeconds
end

function SafeZoneService.isPositionInZone(position: Vector3): boolean
	local anchors = zoneAnchors()
	if #anchors == 0 then
		if not warnedNoZones then
			warnedNoZones = true
			warn("SafeZoneService: no PawnShops or SafeZones in Workspace — nowhere is protected until the level provides them")
		end
		return false
	end

	for _, anchor in anchors do
		if (anchor.Position - position).Magnitude <= SafeZoneConfig.RadiusStuds then
			return true
		end
	end
	return false
end

function SafeZoneService.isInsideZone(character: Model): boolean
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end
	return SafeZoneService.isPositionInZone(root.Position)
end

-- Vehicles are protected by location alone: a van parked outside the shop with
-- a full load is the same griefing target as the player carrying it, and it has
-- no combat tag of its own to reason about.
function SafeZoneService.isModelInZone(model: Model): boolean
	local anchor = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if not anchor then
		return false
	end
	return SafeZoneService.isPositionInZone(anchor.Position)
end

-- Protected means inside a zone AND not carrying a fresh combat tag. Running
-- into a shop mid-fight buys you nothing until the tag expires.
function SafeZoneService.isProtected(character: Model?): boolean
	if not character then
		return false
	end
	if SafeZoneService.isCombatTagged(character) then
		return false
	end
	return SafeZoneService.isInsideZone(character)
end

return SafeZoneService
