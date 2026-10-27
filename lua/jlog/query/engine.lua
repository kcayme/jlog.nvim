-- Query engine over the view's entries (a page or the cross-page matches): filter and group build, in ticks.
local count_mod = require("jlog.query.count")
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local field_cache = require("jlog.query.field_cache")
local filter = require("jlog.query.filter")
local gc = require("jlog.core.gc")
local group = require("jlog.query.group")
local progress_mod = require("jlog.core.progress")
local utils = require("jlog.core.utils")

---@class JLogEngineSource
---@field key string names the workspace in progress messages
---@field entries JLogEntry[]
---@field opts JLogOptions
---@field state JLogWorkspaceState
---@field stored_newest_first boolean
---@field closed boolean|nil

---@class JLogEngine
---@field source JLogEngineSource
---@field generation integer bumped per query; stale chunked queries and counts stop
---@field running boolean the latest query still scans or groups: its items are not handed out yet
---@field matched table<integer, boolean> entry index -> matched the latest query
---@field counter JLogFacetCounter|nil facet counts of the latest query, once complete
---@field counting JLogFacetCounting|nil the latest query's facet count, still running (see `query/count`)
---@field facet_counter JLogFacetCounter fields with a `field=value` filter line, counted as if that line were off
---@field facet_preds table<string, fun(ctx: table): boolean> per such field, the other filter lines
---@field field_cache JLogFieldCache field values read by earlier queries over the same entries
local Engine = {}
Engine.__index = Engine

local M = {}

-- entries scanned between checks of the tick's time budget
local SCAN_BATCH = 500

-- tick_ns: work per tick before yielding (keeps ticks ~16ms)
M.timing = { tick_ns = 12e6 }

---Per field with `field=value` filter groups (see `filter.facet_of`), a predicate of all the other groups.
---@param lines string[]
---@return table<string, fun(ctx: table): boolean>
local function facet_preds(lines)
  local preds = {}

  for field, others in pairs(filter.facet_others(lines)) do
    preds[field] = filter.compile(others)
  end

  return preds
end

---@param source JLogEngineSource
---@return JLogEngine
M.new = function(source)
  return setmetatable({
    source = source,
    generation = 0,
    running = false,
    matched = {},
    facet_counter = facets.counter(),
    facet_preds = {},
    field_cache = field_cache.new(),
  }, Engine)
end

---Filter and group in ticks; work past the first ~12ms tick continues later, a newer query wins.
---@param pred fun(ctx: table): boolean
---@param field string|nil group-by field
---@param on_items fun(items: JLogItem[], shown: integer)
---@param skip_facets boolean|nil no field counts will be shown (sidebar hidden): skip counting picked fields
---@return integer generation
Engine.query = function(self, pred, field, on_items, skip_facets)
  local source = self.source
  local generation = self.generation + 1
  local entries, opts, state = source.entries, source.opts, source.state
  local count = #entries
  local matched = {}
  local group_values = {}
  local entry, entry_index, decoded, decoded_done
  local next_index = 1
  local collected
  local ctx = { raw = "" }
  local preds = skip_facets and {} or facet_preds(state.filters)
  local facet_counter = facets.counter()

  self.generation = generation
  self.running = true
  self.matched = matched
  self.facet_counter, self.facet_preds = facet_counter, preds

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
  local function read_entry(path)
    local value, found = entry_model.peek(entry, path, opts)

    if found then
      return value
    end

    return entry_model.get(entry, current_decoded(), path, opts)
  end
  -- a field read by an earlier query over these entries is not read again
  local function read(path)
    return field_cache.get(self.field_cache, entry_index, entry, path, read_entry)
  end
  ctx.get = read
  field_cache.use(self.field_cache, entries)

  local function scan(first, last)
    for index = first, last do
      entry, entry_index, decoded_done = entries[index], index, false
      ctx.raw = entry_model.key(entry)
      if pred(ctx) then
        matched[index] = true
      end
      -- a filtered field counts every entry its own line alone would drop, so all its values stay listed
      for name, field_pred in pairs(preds) do
        if matched[index] or field_pred(ctx) then
          facets.add_value(facet_counter, name, read(name))
        end
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

    progress_mod.finish(source.key, "apply", "applying done")
    build = coroutine.create(function()
      return group.build(count, {
        pred = function(index)
          return matched[index] == true
        end,
        field = field,
        reverse = state.reverse,
        limit = state.limit,
        group_limit = state.group_limit,
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
        self.running = false
        error(items, 0)
      end
      if coroutine.status(build) ~= "dead" then
        yielded = true
        vim.defer_fn(resume, 0)

        return
      end
      if not yielded then
        self.running = false
        on_items(items, shown)

        return
      end
      vim.defer_fn(function()
        if not stale() then
          self.running = false
          on_items(items, shown)
        end
      end, 0)
    end

    resume()
  end

  ---@param sync boolean|nil the first tick, run by query itself: work that fits in it finishes at once
  local function step(sync)
    local deadline = sync and vim.uv.hrtime() + M.timing.tick_ns or utils.tick_deadline(M.timing.tick_ns)
    local last, ok, err

    if stale() then
      return
    end
    repeat
      last = math.min(next_index + SCAN_BATCH - 1, count)
      ok, err = pcall(scan, next_index, last)
      if not ok then
        -- a query that failed hands out no items, so it must not keep the view waiting for them
        self.running = false
        error(err, 0)
      end
      next_index = last + 1
    until next_index > count or vim.uv.hrtime() >= deadline
    if next_index > count and sync then
      finish(true)

      return
    end
    -- let the collector finish its cycle in time-boxed steps, or its debt lands on finish in one long tick
    if next_index > count and not collected then
      collected = gc.step(deadline)
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
      progress_mod.begin(source.key, "apply", "applying…")
    end
    -- a timer, not vim.schedule: chained scheduled callbacks run back to back without handling input or redraw
    vim.defer_fn(step, 0)
  end

  step(true)

  return generation
end

---Use counts that are already known, such as those of a load, or none.
---@param counter JLogFacetCounter|nil
Engine.set_counts = function(self, counter)
  self.counter = counter
  self.counting = nil
end

Engine.count = count_mod.run
Engine.count_appended = count_mod.appended
Engine.count_unmatched_appended = count_mod.unmatched_appended

return M
