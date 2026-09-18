--!strict
-- Client mirror of SystemsBootstrap: requires client modules that register
-- listeners as a side effect, so they're live before any UI is built.

require(script.Parent:WaitForChild("FactionController"))
require(script.Parent:WaitForChild("PlayerStateController"))
require(script.Parent:WaitForChild("ShopController"))
require(script.Parent:WaitForChild("InventoryUI"))
