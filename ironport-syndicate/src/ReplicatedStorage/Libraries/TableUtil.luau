--!strict
local TableUtil = {}

function TableUtil.shallowCopy<T>(source: { [any]: T }): { [any]: T }
	local copy = {}
	for key, value in source do
		copy[key] = value
	end
	return copy
end

return TableUtil
