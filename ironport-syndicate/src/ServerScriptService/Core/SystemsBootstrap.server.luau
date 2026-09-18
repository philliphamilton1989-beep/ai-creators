--!strict
-- Starts the systems whose remote handlers register as a side effect of being
-- required.
--
-- This replaces the original scaffold's use of `_G` for cross-script wiring:
-- `_G.ProcessDamage`/`_G.AddHeat` depended on Roblox's script execution order,
-- which is not guaranteed, and the "fix" was a blind `task.wait(0.25)` that
-- could still fail silently under load. `require()` is deterministic — a
-- module is guaranteed fully loaded before the requiring script continues.
--
-- Each require is isolated. A plain sequence of requires meant one broken
-- module took out every system listed after it, which is exactly what happened:
-- LaunderingService was missing its module-level return, so the require threw
-- here and Heists and Territory — required nowhere else — never started at all,
-- with nothing in the log pointing at the cause.

local serverScriptService = script.Parent.Parent

local function startSystem(folderName: string, moduleName: string)
	local ok, err = pcall(function()
		local folder = serverScriptService:WaitForChild(folderName)
		require(folder:WaitForChild(moduleName))
	end)
	if not ok then
		warn(("SystemsBootstrap: %s.%s failed to start: %s"):format(folderName, moduleName, tostring(err)))
	end
end

startSystem("Defense", "RaidService")
startSystem("Economy", "LaunderingService")
startSystem("Heists", "HeistService")
startSystem("Factions", "FactionService")
startSystem("Factions", "TerritoryService")
startSystem("Vehicles", "VehicleService")
startSystem("Vehicles", "VehicleDamageService")
startSystem("Monetization", "GamePassService")
startSystem("Inventory", "InventoryService")
startSystem("Inventory", "DeathDropService")
startSystem("Inventory", "ScavengeService")
startSystem("Inventory", "ValuableSpawnService")
startSystem("Economy", "PawnShopService")
startSystem("Core", "HeatService")
