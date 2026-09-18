--!strict
-- Validation for numbers that arrive from a client.
--
-- NaN is the trap worth naming: every comparison involving it is false, so a
-- NaN amount slips past both `amount <= 0` and `amount > balance` and lands in
-- the economy, where it poisons the value permanently (any arithmetic with NaN
-- is NaN) and then breaks DataStore writes, since JSON has no NaN.

local Numeric = {}

function Numeric.isFinite(value: any): boolean
	if typeof(value) ~= "number" then
		return false
	end
	-- NaN fails equality with itself; the infinities are excluded explicitly.
	return value == value and value ~= math.huge and value ~= -math.huge
end

-- As isFinite, but for a Vector3 arriving from a client (an aim or fire
-- direction). NaN in any component makes Magnitude NaN too, which fails every
-- comparison including with itself — so it slips past a plain
-- `Magnitude == 0` guard and reaches Workspace:Raycast.
function Numeric.isFiniteVector(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local magnitude = value.Magnitude
	return magnitude == magnitude and magnitude > 0 and magnitude ~= math.huge
end

-- Returns a whole, positive, finite amount, or nil if the input can't be one.
-- Cash is always an integer: fractional currency has no representation in the
-- UI and accumulates rounding drift across laundering and treasury splits.
function Numeric.toCashAmount(value: any): number?
	if not Numeric.isFinite(value) then
		return nil
	end
	local amount = math.floor(value :: number)
	if amount <= 0 then
		return nil
	end
	return amount
end

return Numeric
