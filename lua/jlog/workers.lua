local M = {}

local work_handle
local failed = false
local next_id = 0
local callbacks = {}
local pending = 0

local plugin_lua = debug.getinfo(1, "S").source:sub(2):match("^(.*)/jlog/workers%.lua$")

-- The work function is string.dump-ed to the thread: no upvalues, everything arrives as arguments.
local function work_fn(path, job, payload, id)
  local ok, result

  package.path = path
  ok, result = pcall(function()
    return require("jlog.jobs")[job](payload)
  end)
  collectgarbage()

  return id, ok, result
end

local function on_work_done(id, ok, result)
  local callback = callbacks[id]

  callbacks[id] = nil
  pending = pending - 1
  vim.defer_fn(function()
    if ok then
      callback(nil, result)
    else
      callback(tostring(result), nil)
    end
  end, 0)
end

M.disabled = nil

---@return integer
M.limit = function()
  return math.max(1, (tonumber(os.getenv("UV_THREADPOOL_SIZE")) or 4) - 1)
end

---@return boolean
M.available = function()
  return not (M.disabled or failed)
end

---@return integer
M.in_flight = function()
  return pending
end

---Runs a job from jlog.jobs on a worker thread; on_result runs on the main loop.
---@param job string
---@param payload string
---@param on_result fun(err: string|nil, result: string|nil)
M.run = function(job, payload, on_result)
  local path

  if not work_handle then
    work_handle = vim.uv.new_work(work_fn, on_work_done)
  end
  if not work_handle then
    failed = true
    vim.defer_fn(function()
      on_result("worker threads unavailable", nil)
    end, 0)

    return
  end

  path = package.path .. ";" .. plugin_lua .. "/?.lua;" .. plugin_lua .. "/?/init.lua"
  next_id = next_id + 1
  callbacks[next_id] = on_result
  pending = pending + 1
  work_handle:queue(path, job, payload, next_id)
end

return M
