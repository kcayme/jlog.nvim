-- Sends one caller's jobs to worker threads: each result lands on its job; tracks the caller's progress and stalls.
local workers = require("jlog.worker")

---@class JLogDispatcher
---@field at integer `vim.uv.now()` when a job was last sent or reported, or the caller last made progress

---@class JLogJob
---@field done boolean|nil
---@field err string|nil
---@field result string|nil the job's mpack result

local M = {}

M.available = workers.available

---@return JLogDispatcher
M.new = function()
  return { at = vim.uv.now() }
end

---Whether a caller with `out` jobs out may send one more: under its own cap and the cap shared by every caller.
---@param out integer
---@return boolean
M.has_room = function(out)
  return out < workers.limit() and workers.in_flight() < workers.limit()
end

---Send `job` to the worker job `name` with `payload`; its `done`, `err` and `result` are set when it reports.
---@param dispatcher JLogDispatcher
---@param name string a job of `worker/jobs`
---@param payload table encoded here with vim.mpack
---@param job JLogJob
---@return JLogJob job
M.send = function(dispatcher, name, payload, job)
  -- the callback holds only the job and the dispatcher, so a dropped caller keeps nothing else alive
  workers.run(name, vim.mpack.encode(payload), function(err, result)
    job.done, job.err, job.result = true, err, result
    dispatcher.at = vim.uv.now()
  end)
  dispatcher.at = vim.uv.now()

  return job
end

---Note progress made on the main thread, so time spent on it is not taken for a stall.
---@param dispatcher JLogDispatcher
M.progress = function(dispatcher)
  dispatcher.at = vim.uv.now()
end

---Whether nothing was sent, reported or done for `workers.stall_ms`: the caller should stop waiting on workers.
---@param dispatcher JLogDispatcher
---@return boolean
M.stalled = function(dispatcher)
  return vim.uv.now() - dispatcher.at > workers.stall_ms
end

return M
