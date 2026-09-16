--!strict
-- Shared retry wrapper for DataStore calls. A transient DataStore failure is
-- retried with backoff rather than silently dropping the write; callers decide
-- what to do when it ultimately fails.

local RETRY_ATTEMPTS = 3
local RETRY_BACKOFF_SECONDS = 1.5

local DataStoreRetry = {}

function DataStoreRetry.run<T>(label: string, fn: () -> T): (boolean, T?)
	for attempt = 1, RETRY_ATTEMPTS do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		warn(("%s: attempt %d/%d failed: %s"):format(label, attempt, RETRY_ATTEMPTS, tostring(result)))
		if attempt < RETRY_ATTEMPTS then
			task.wait(RETRY_BACKOFF_SECONDS * attempt)
		end
	end
	return false, nil
end

return DataStoreRetry
