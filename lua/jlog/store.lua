local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local group = require("jlog.query.group")
local utils = require("jlog.utils")

---@class JLogStoreSource
---@field entries JLogEntry[]
---@field opts JLogOptions
---@field state JLogWorkspaceState
---@field stored_newest_first boolean
---@field closed boolean|nil

---@class JLogFacetCounting
---@field counter JLogFacetCounter
---@field matched table<integer, boolean> entry index -> matched the query's filters
---@field next_index integer

---@class JLogStore
---@field source JLogStoreSource
---@field generation integer bumped per query; stale chunked queries and counts stop
---@field matched table<integer, boolean> entry index -> matched the latest query
---@field counter JLogFacetCounter|nil facet counts of the latest query, once complete
---@field counting JLogFacetCounting|nil the latest query's facet count, still running
local Store = {}
Store.__index = Store

local M = {}

-- entries scanned between checks of the tick's time budget
local SCAN_BATCH = 500
-- entries looked at between checks of the tick's time budget while counting facets
local COUNT_BATCH = 100

-- tick_ns: work per tick before yielding (keeps ticks ~16ms)
M.timing = { tick_ns = 12e6 }

---@param source JLogStoreSource
---@return JLogStore
M.new = function(source)
  return setmetatable({ source = source, generation = 0, matched = {} }, Store)
end

---Filter and group in ticks; work past the first ~12ms tick continues later, a newer query wins.
---@param pred fun(ctx: table): boolean
---@param field string|nil group-by field
---@param on_items fun(items: JLogItem[], shown: integer)
---@return integer generation
Store.query = function(self, pred, field, on_items)
  local source = self.source
  local generation = self.generation + 1
  local entries, opts, state = source.entries, source.opts, source.state
  local count = #entries
  local matched = {}
  local group_values = {}
  local entry, decoded, decoded_done
  local next_index = 1
  local collected
  local notified = false
  local ctx = { raw = "" }

  self.generation = generation
  self.matched = matched

  local function stale()
    return self.generation ~= generation or source.closed
  end
  -- each entry is decoded at most once per scan, and only when a filter or group needs it
  local function current_decoded()
    if not decoded_done then
      decoded, decoded_done = entry_model.decode(entry), true
    end

    return decoded
  end
  -- simple top-level values are read from the text, the rest from the decode
  local function read(path)
    local value, found = entry_model.peek(entry, path, opts)

    if found then
      return value
    end

    return entry_model.get(entry, current_decoded(), path, opts)
  end
  ctx.get = read

  local function scan(first, last)
    for index = first, last do
      entry, decoded_done = entries[index], false
      ctx.raw = entry_model.key(entry)
      if pred(ctx) then
        matched[index] = true
      end
      if field then
        -- read now, in the time-boxed scan: decoding again while building groups is one long tick
        group_values[index] = read(field)
      end
    end
    entry, decoded = nil, nil
  end

  -- group.build in a coroutine that yields when the tick is up; a build spanning ticks reports in a tick of its own
  ---@param sync boolean|nil run by the query's own first tick
  local function finish(sync)
    local build_deadline
    local yielded = false
    local build

    if notified then
      vim.notify("jlog: applying done", vim.log.levels.INFO)
    end
    build = coroutine.create(function()
      return group.build(count, {
        pred = function(index)
          return matched[index] == true
        end,
        field = field,
        reverse = state.reverse,
        newest_first = source.stored_newest_first,
        get = function(index)
          return group_values[index]
        end,
        checkpoint = function()
          if vim.uv.hrtime() >= build_deadline then
            coroutine.yield()
          end
        end,
      })
    end)

    local function resume()
      local ok, items, shown

      if stale() then
        return
      end
      -- the query's own first tick keeps its full budget: the pass's may be spent by callbacks run before it
      build_deadline = sync and vim.uv.hrtime() + M.timing.tick_ns or utils.tick_deadline(M.timing.tick_ns)
      sync = false
      ok, items, shown = coroutine.resume(build)
      if not ok then
        error(items, 0)
      end
      if coroutine.status(build) ~= "dead" then
        yielded = true
        vim.defer_fn(resume, 0)

        return
      end
      if not yielded then
        on_items(items, shown)

        return
      end
      vim.defer_fn(function()
        if not stale() then
          on_items(items, shown)
        end
      end, 0)
    end

    resume()
  end

  ---@param sync boolean|nil the first tick, run by query itself: work that fits in it finishes at once
  local function step(sync)
    local deadline = sync and vim.uv.hrtime() + M.timing.tick_ns or utils.tick_deadline(M.timing.tick_ns)
    local last

    if stale() then
      return
    end
    repeat
      last = math.min(next_index + SCAN_BATCH - 1, count)
      scan(next_index, last)
      next_index = last + 1
    until next_index > count or vim.uv.hrtime() >= deadline
    if next_index > count and sync then
      finish(true)

      return
    end
    -- let the collector finish its cycle in time-boxed steps, or its debt lands on finish in one long tick
    if next_index > count and not collected then
      repeat
        -- selene: allow(incorrect_standard_library_use)
        collected = collectgarbage("step", 0)
      until collected or vim.uv.hrtime() >= deadline
    end
    if next_index > count and collected then
      -- grouping and the first render get a tick of their own
      vim.defer_fn(function()
        if not stale() then
          finish()
        end
      end, 0)

      return
    end
    if sync then
      notified = true
      vim.notify("jlog: applying…", vim.log.levels.INFO)
    end
    -- a timer, not vim.schedule: chained scheduled callbacks run back to back without handling input or redraw
    vim.defer_fn(step, 0)
  end

  step(true)

  return generation
end

---Use counts that are already known, such as those of a load, or none.
---@param counter JLogFacetCounter|nil
Store.set_counts = function(self, counter)
  self.counter = counter
  self.counting = nil
end

---Count the facets of the matched entries in ticks, then call `on_done`; a newer query stops it.
---@param on_done fun(counter: JLogFacetCounter)
Store.count = function(self, on_done)
  local generation = self.generation
  local counting = { counter = facets.counter(), matched = self.matched, next_index = 1 }
  local function tick()
    local deadline = utils.tick_deadline(M.timing.tick_ns)
    local entries = self.source.entries
    local last, entry

    if self.source.closed or self.generation ~= generation then
      return
    end
    repeat
      last = math.min(counting.next_index + COUNT_BATCH - 1, #entries)
      for index = counting.next_index, last do
        if counting.matched[index] then
          entry = entries[index]
          facets.add(counting.counter, entry_model.flatten(entry, entry_model.decode(entry)))
        end
      end
      counting.next_index = last + 1
    until counting.next_index > #entries or vim.uv.hrtime() >= deadline
    if counting.next_index <= #entries then
      vim.defer_fn(tick, 0)

      return
    end

    self.counting = nil
    self.counter = counting.counter
    on_done(counting.counter)
  end

  -- set up now so appends join it; counting starts in a tick of its own
  self.counting = counting
  vim.defer_fn(tick, 0)
end

---An entry appended after the query that matched: a running count takes it into its pass, a finished one adds it.
---@param index integer
---@param entry JLogEntry
---@param decoded table|nil
Store.count_appended = function(self, index, entry, decoded)
  if self.counting then
    self.counting.matched[index] = true
  elseif self.counter then
    facets.add(self.counter, entry_model.flatten(entry, decoded))
  end
end

return M
