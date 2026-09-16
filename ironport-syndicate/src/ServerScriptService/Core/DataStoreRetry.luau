--!strict
-- Shared retry wrapper for DataStore calls. A transient failure is retried,
-- waiting longer before each attempt, rather than silently dropping the write.
-- Callers decide what to do when it ultimately fails.
--
-- ONLY WRAP IDEMPOTENT OPERATIONS. GetAsync, SetAsync and RemoveAsync are safe
-- to repeat. An UpdateAsync whose transform is additive is NOT: a call can
-- commit on the server and still report failure (a lost response, a timeout),
-- and the retry then applies the same delta a second time. A caller doing
-- additive updates has to carry its own idempotency — see the flush token in
-- FactionService — because no retry policy here can make that safe.
--
-- Failure is also not always transient. A payload that can't be serialised, or
-- one over the size limit, will fail identically every time and just burns the
-- attempts. Those aren't filtered out, because the only way to detect them is
-- matching Roblox's error text, and misclassifying a transient failure as
-- permanent silently drops a save — a worse outcome than a wasted retry.

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
