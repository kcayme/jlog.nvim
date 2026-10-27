-- Query engine over the view's entries (a page or the cross-page matches): filter, group build and field counts.
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local filter = require("jlog.query.filter")
local gc = require("jlog.core.gc")
local group = require("jlog.query.group")
local progress_mod = require("jlog.core.progress")
local utils = require("jlog.core.utils")
local workers = require("jlog.worker")

---@class JLogEngineSource
---@field key string names the workspace in progress messages
---@field entries JLogEntry[]
---@field opts JLogOptions
---@field state JLogWorkspaceState
---@field stored_newest_first boolean
---@field closed boolean|nil

---@class JLogFacetCounting
---@field counter JLogFacetCounter
---@field matched table<integer, boolean> entry index -> matched the query's filters
---@field next_index integer

---@class JLogEngine
---@field source JLogEngineSource
---@field generation integer bumped per query; stale chunked queries and counts stop
---@field running boolean the latest query still scans or groups: its items are not handed out yet
---@field matched table<integer, boolean> entry index -> matched the latest query
---@field counter JLogFacetCounter|nil facet counts of the latest query, once complete
---@field counting JLogFacetCounting|nil the latest query's facet count, still running
---@field facet_counter JLogFacetCounter fields with a `field=value` filter line, counted as if that line were off
---@field facet_preds table<string, fun(ctx: table): boolean> per such field, the other filter lines
local Engine = {}
Engine.__index = Engine

local M = {}

-- entries scanned between checks of the tick's time budget
local SCAN_BATCH = 500
-- entries looked at between checks of the tick's time budget while counting facets
local COUNT_BATCH = 100
-- ms between checks for a worker result while every job slot is busy
local COUNT_WAIT_MS = 2

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

-- a match smaller than this is counted on the main thread
M.count_min = 2000
-- about this many bytes of entry text go to one worker job
M.count_batch_bytes = 256 * 1024

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
  local entry, decoded, decoded_done
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

---@param matched table<integer, boolean>
---@return boolean
local function matches_at_least(matched, minimum)
  local seen = 0

  for _ in pairs(matched) do
    seen = seen + 1
    if seen >= minimum then
      return true
    end
  end

  return false
end

---Count `list` entries on the main thread into `counter`.
---@param counter JLogFacetCounter
---@param list JLogEntry[]
local function count_here(counter, list)
  for _, entry in ipairs(list) do
    facets.add(counter, entry_model.flatten(entry, entry_model.decode(entry)))
  end
end

---Send a batch of entries to a worker; its `done`, `err` and `result` are set when it reports.
---@param list JLogEntry[]
---@param progress { at: integer } its `at` set to `vim.uv.now()` when the batch reports
---@return table batch
local function dispatch_batch(list, progress)
  local batch = { entries = list }
  local items = {}

  for index, entry in ipairs(list) do
    -- text that is not JSON is never decoded, so only its labels travel
    items[index] = { body = entry.json_at and entry.body or "", json_at = entry.json_at, labels = entry.labels }
  end
  workers.run("count_entries", vim.mpack.encode({ entries = items }), function(err, result)
    batch.done, batch.err, batch.result = true, err, result
    progress.at = vim.uv.now()
  end)

  return batch
end

---Count the facets of the matched entries in ticks, then call `on_done`; a newer query stops it.
---@param on_done fun(counter: JLogFacetCounter)
Engine.count = function(self, on_done)
  local generation = self.generation
  local counting = { counter = facets.counter(), matched = self.matched, next_index = 1 }
  local facet_counter = self.facet_counter
  -- threaded path: batches out, batch being filled, and its text size
  local own, building, building_bytes = {}, {}, 0
  -- when a batch was last dispatched or returned; past `workers.stall_ms` the rest is counted here
  local progress, stalled = { at = vim.uv.now() }, false
  local tick_threaded
  local function done()
    facets.override(counting.counter, facet_counter)
    self.counting = nil
    self.counter = counting.counter
    on_done(counting.counter)
  end
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

    done()
  end

  tick_threaded = function()
    local batch
    local deadline = utils.tick_deadline(M.timing.tick_ns)
    local entries = self.source.entries
    local usable, complete, entry
    local blocked = false

    if self.source.closed or self.generation ~= generation then
      return
    end
    for index = #own, 1, -1 do
      if own[index].done then
        batch = table.remove(own, index)
        if batch.err then
          count_here(counting.counter, batch.entries)
        else
          facets.merge(counting.counter, vim.mpack.decode(batch.result).fields)
        end
      end
    end
    if not own[1] and workers.in_flight() < workers.limit() then
      -- not waiting on workers, so time spent filling a batch is not a stall
      progress.at = vim.uv.now()
    elseif not stalled and vim.uv.now() - progress.at > workers.stall_ms then
      -- batches still out are dropped, so their late results are never merged
      stalled = true
      for _, out in ipairs(own) do
        count_here(counting.counter, out.entries)
        -- the transport keeps the batch until its worker answers, which may be never
        out.entries = nil
      end
      own = {}
    end
    repeat
      usable = workers.available() and not stalled
      if usable and (#own >= workers.limit() or workers.in_flight() >= workers.limit()) then
        blocked = true

        break
      end
      while counting.next_index <= #entries do
        entry = entries[counting.next_index]
        if counting.matched[counting.next_index] then
          building[#building + 1] = entry
          building_bytes = building_bytes + #entry.body
        end
        counting.next_index = counting.next_index + 1
        if building_bytes >= M.count_batch_bytes then
          break
        end
        if counting.next_index % COUNT_BATCH == 0 and vim.uv.hrtime() >= deadline then
          break
        end
      end
      complete = building_bytes >= M.count_batch_bytes or (counting.next_index > #entries and building[1] ~= nil)
      if complete and usable then
        own[#own + 1] = dispatch_batch(building, progress)
        progress.at = vim.uv.now()
      elseif complete then
        count_here(counting.counter, building)
      end
      if complete then
        building, building_bytes = {}, 0
      end
    until not complete or vim.uv.hrtime() >= deadline
    if counting.next_index <= #entries or building[1] or own[1] then
      -- stopped short of the deadline for a result or a free slot: wait instead of spinning
      vim.defer_fn(tick_threaded, (own[1] or blocked) and vim.uv.hrtime() < deadline and COUNT_WAIT_MS or 0)

      return
    end

    done()
  end

  -- set up now so appends join it; counting starts in a tick of its own
  self.counting = counting
  vim.defer_fn(workers.available() and matches_at_least(counting.matched, M.count_min) and tick_threaded or tick, 0)
end

---An entry appended after the query that matched: a running count takes it into its pass, a finished one adds it.
---@param index integer
---@param entry JLogEntry
---@param decoded table|nil
Engine.count_appended = function(self, index, entry, decoded)
  if self.counting then
    self.counting.matched[index] = true
    -- the count's own values of these fields are replaced by the facet counts when it finishes
    for name in pairs(self.facet_preds) do
      facets.add_value(self.facet_counter, name, entry_model.get(entry, decoded, name, self.source.opts))
    end
  elseif self.counter then
    -- a finished count shares the facet counts' fields, so this adds to them too
    facets.add(self.counter, entry_model.flatten(entry, decoded))
  end
end

---An appended entry that misses some filter line: it still counts for a field whose own lines alone dropped it.
---@param ctx JLogMatchCtx the entry's match context
Engine.count_unmatched_appended = function(self, ctx)
  -- a finished count holds the facet fields; a query that kept it (reverse) made a facet counter it never took
  local target = self.counting and self.facet_counter or self.counter

  if not target then
    return
  end
  for name, field_pred in pairs(self.facet_preds) do
    -- into a finished count only fields it lists, as `facets.override` skipped aliased names it lacked
    if field_pred(ctx) and (self.counting or target.fields[name]) then
      facets.add_value(target, name, ctx.get(name))
    end
  end
end

return M
