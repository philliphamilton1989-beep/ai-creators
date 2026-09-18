--!strict
-- Generators: the thing turrets run on, and the thing raiders should be
-- attacking instead of the turrets.
--
-- Taken straight from ARK's lesson. A turret line with no power source has
-- exactly one counterplay — grind through its ammo — which is a timer rather
-- than a tactic. Give the line a generator and a raid gains a real objective:
-- push to the generator, kill it, and the whole perimeter goes dark at once.
-- That is also what makes the armored vehicle worth its price, since surviving
-- the approach is the point rather than out-tanking every gun.
--
-- A generator is any Model under Workspace.Generators. It burns fuel while
-- powering turrets, is refuelled by hand from a player's inventory, and is
-- destructible.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InventoryService = require(script.Parent.Parent:WaitForChild("Inventory"):WaitForChild("InventoryService"))
local TurretConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("TurretConfig"))

local PowerService = {}

type GeneratorState = {
	Model: Model,
	Anchor: BasePart,
	Fuel: number,
	-- Total draw of everything it powered last tick, used to burn fuel.
	Load: number,
}

local generators: { [Model]: GeneratorState } = {}

local function setFuel(state: GeneratorState, fuel: number)
	state.Fuel = math.clamp(fuel, 0, TurretConfig.Power.MaxFuel)
	state.Model:SetAttribute("Fuel", math.floor(state.Fuel))
	state.Model:SetAttribute("Powered", state.Fuel > 0 and state.Model:GetAttribute("GeneratorDestroyed") ~= true)
end

-- The generator powering a point, if any has fuel left. Returns the state so
-- the caller can register its draw.
function PowerService.findPowerFor(position: Vector3): GeneratorState?
	local radius = TurretConfig.Power.GeneratorRadiusStuds
	for _, state in generators do
		if state.Model:GetAttribute("GeneratorDestroyed") == true or state.Fuel <= 0 then
			continue
		end
		if (state.Anchor.Position - position).Magnitude <= radius then
			return state
		end
	end
	return nil
end

-- Turrets call this each tick they want to run. Draw is accumulated and burned
-- on the generator's own step, so fuel cost scales with how much is actually
-- being powered rather than with how many turrets merely exist.
function PowerService.requestPower(position: Vector3, draw: number): boolean
	local state = PowerService.findPowerFor(position)
	if not state then
		return false
	end
	state.Load += draw
	return true
end

function PowerService.takeDamage(model: Model, damage: number, attacker: Player?): number
	local state = generators[model]
	if not state or model:GetAttribute("GeneratorDestroyed") == true then
		return 0
	end

	local health = model:GetAttribute("GeneratorHealth")
	if typeof(health) ~= "number" then
		return 0
	end

	local remaining = math.max(0, health - damage)
	model:SetAttribute("GeneratorHealth", remaining)

	if remaining <= 0 then
		model:SetAttribute("GeneratorDestroyed", true)
		model:SetAttribute("Powered", false)
		-- Everything it was powering goes dark on the turrets' next tick; no
		-- push needed, because they ask for power rather than being told.
	end
	return damage
end

function PowerService.findGeneratorFromPart(part: BasePart): Model?
	local current: Instance? = part
	while current and current ~= Workspace do
		if current:IsA("Model") and generators[current :: Model] then
			return current :: Model
		end
		current = current.Parent
	end
	return nil
end

function PowerService.refuel(player: Player, model: Model): (boolean, string)
	local state = generators[model]
	if not state then
		return false, "NotAGenerator"
	end
	if model:GetAttribute("GeneratorDestroyed") == true then
		return false, "GeneratorDestroyed"
	end
	if state.Fuel >= TurretConfig.Power.MaxFuel then
		return false, "AlreadyFull"
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or (root.Position - state.Anchor.Position).Magnitude > TurretConfig.Power.RefuelRangeStuds then
		return false, "TooFarAway"
	end

	if not InventoryService.removeItem(player, "FuelCan", 1) then
		return false, "NoFuelCan"
	end

	setFuel(state, state.Fuel + TurretConfig.Power.FuelPerCan)
	return true, "Refuelled"
end

local function registerGenerator(instance: Instance)
	if not instance:IsA("Model") or generators[instance] then
		return
	end

	local anchor = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart")
	if not anchor then
		warn(("PowerService: %s has no BasePart; skipping"):format(instance:GetFullName()))
		return
	end

	local state: GeneratorState = {
		Model = instance,
		Anchor = anchor,
		Fuel = 0,
		Load = 0,
	}
	generators[instance] = state

	instance:SetAttribute("GeneratorHealth", TurretConfig.Power.GeneratorHealth)
	instance:SetAttribute("GeneratorMaxHealth", TurretConfig.Power.GeneratorHealth)
	instance:SetAttribute("GeneratorDestroyed", false)
	setFuel(state, 0)

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Refuel"
	prompt.ObjectText = "Generator"
	prompt.HoldDuration = 1.2
	prompt.MaxActivationDistance = TurretConfig.Power.RefuelRangeStuds
	prompt.RequiresLineOfSight = false
	prompt.Parent = anchor
	prompt.Triggered:Connect(function(player: Player)
		PowerService.refuel(player, instance)
	end)
end

local function bindFolder(folder: Instance)
	for _, child in folder:GetChildren() do
		registerGenerator(child)
	end
	folder.ChildAdded:Connect(registerGenerator)
	folder.ChildRemoved:Connect(function(child)
		generators[child :: Model] = nil
	end)
end

-- Burns whatever load was requested since the last tick, then clears it. A
-- generator idling with nothing to power costs nothing, so a defender isn't
-- punished for being left alone.
task.spawn(function()
	while true do
		task.wait(1)
		for _, state in generators do
			if state.Load > 0 and state.Fuel > 0 then
				setFuel(state, state.Fuel - state.Load * TurretConfig.Power.FuelPerPowerSecond)
			end
			state.Load = 0
		end
	end
end)

local folder = Workspace:FindFirstChild("Generators")
if folder then
	bindFolder(folder)
else
	warn("PowerService: no Workspace.Generators folder — turrets have no power source until the level provides one")
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == "Generators" then
			bindFolder(child)
		end
	end)
end

return PowerService
