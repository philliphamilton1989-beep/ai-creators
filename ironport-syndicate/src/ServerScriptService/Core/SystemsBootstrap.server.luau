--!strict
-- Explicitly requires modules that register their remote handlers as a side
-- effect of being required (RaidService, LaunderingService, HeatService).
--
-- This replaces the original scaffold's use of `_G` for cross-script wiring:
-- `_G.ProcessDamage`/`_G.AddHeat` depended on Roblox's script execution order,
-- which is not guaranteed, and the "fix" was a blind `task.wait(0.25)` that
-- could still fail silently under load. `require()` is deterministic — a
-- module is guaranteed fully loaded before the requiring script continues.

local factions = script.Parent.Parent:WaitForChild("Factions")

require(script.Parent.Parent:WaitForChild("Defense"):WaitForChild("RaidService"))
require(script.Parent.Parent:WaitForChild("Economy"):WaitForChild("LaunderingService"))
require(script.Parent.Parent:WaitForChild("Heists"):WaitForChild("HeistService"))
require(factions:WaitForChild("FactionService"))
require(factions:WaitForChild("TerritoryService"))
require(script.Parent:WaitForChild("HeatService"))
