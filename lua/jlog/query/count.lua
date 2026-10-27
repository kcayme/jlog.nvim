-- Field counts for FIELDS over an engine's matched entries: on worker threads in batches, or on the main thread.
local dispatcher = require("jlog.worker.dispatcher")
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local utils = require("jlog.core.utils")

---@class JLogFacetCounting
---@field counter JLogFacetCounter
---@field matched table<integer, boolean> entry index -> matched the query's filters
---@field next_index integer

local M = {}

-- entries looked at between checks of the tick's time budget
local COUNT_BATCH = 100
-- ms between checks for a worker result while every job slot is busy
local COUNT_WAIT_MS = 2

-- tick_ns: work per tick before yielding
M.timing = { tick_ns = 12e6 }
-- a match smaller than this is counted on the main thread
M.min = 2000
-- about this many bytes of entry text go to one worker job
M.batch_bytes = 256 * 1024

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

---Send a batch of entries to a worker; its `done`, `err` and `result` are set when it reports.
---@param sender JLogDispatcher
---@param list JLogEntry[]
---@return table batch
local function dispatch_batch(sender, list)
  local items = {}

  for index, entry in ipairs(list) do
    -- text that is not JSON is never decoded, so only its labels travel
    items[index] = { body = entry.json_at and entry.body or "", json_at = entry.json_at, labels = entry.labels }
  end

  return dispatcher.send(sender, "count_entries", { entries = items }, { entries = list })
end

---Count the facets of the matched entries in ticks, then call `on_done`; a newer query stops it.
---@param engine JLogEngine
---@param on_done fun(counter: JLogFacetCounter)
M.run = function(engine, on_done)
  local generation = engine.generation
  local counting = { counter = facets.counter(), matched = engine.matched, next_index = 1 }
  local facet_counter = engine.facet_counter
  -- threaded path: batches out, batch being filled, and its text size
  local own, building, building_bytes = {}, {}, 0
  -- when a batch was last dispatched or returned; past `workers.stall_ms` the rest is counted here
  local sender, stalled = dispatcher.new(), false
  local tick_threaded
  local function done()
    facets.override(counting.counter, facet_counter)
    engine.counting = nil
    engine.counter = counting.counter
    on_done(counting.counter)
  end
  local function tick()
    local deadline = utils.tick_deadline(M.timing.tick_ns)
    local entries = engine.source.entries
    local last, entry

    if engine.source.closed or engine.generation ~= generation then
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
    local entries = engine.source.entries
    local usable, complete, entry
    local blocked = false

    if engine.source.closed or engine.generation ~= generation then
      return
    end
    for index = #own, 1, -1 do
      if own[index].done then
        batch = table.remove(own, index)
        if batch.err then
          facets.count_entries(counting.counter, batch.entries)
        else
          facets.merge(counting.counter, vim.mpack.decode(batch.result).fields)
        end
      end
    end
    if not own[1] and dispatcher.has_room(0) then
      -- not waiting on workers, so time spent filling a batch is not a stall
      dispatcher.progress(sender)
    elseif not stalled and dispatcher.stalled(sender) then
      -- batches still out are dropped, so their late results are never merged
      stalled = true
      for _, out in ipairs(own) do
        facets.count_entries(counting.counter, out.entries)
        -- the transport keeps the batch until its worker answers, which may be never
        out.entries = nil
      end
      own = {}
    end
    repeat
      usable = dispatcher.available() and not stalled
      if usable and not dispatcher.has_room(#own) then
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
        if building_bytes >= M.batch_bytes then
          break
        end
        if counting.next_index % COUNT_BATCH == 0 and vim.uv.hrtime() >= deadline then
          break
        end
      end
      complete = building_bytes >= M.batch_bytes or (counting.next_index > #entries and building[1] ~= nil)
      if complete and usable then
        own[#own + 1] = dispatch_batch(sender, building)
      elseif complete then
        facets.count_entries(counting.counter, building)
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
  engine.counting = counting
  vim.defer_fn(dispatcher.available() and matches_at_least(counting.matched, M.min) and tick_threaded or tick, 0)
end

---An entry appended after the query that matched: a running count takes it into its pass, a finished one adds it.
---@param engine JLogEngine
---@param index integer
---@param entry JLogEntry
---@param decoded table|nil
M.appended = function(engine, index, entry, decoded)
  if engine.counting then
    engine.counting.matched[index] = true
    -- the count's own values of these fields are replaced by the facet counts when it finishes
    for name in pairs(engine.facet_preds) do
      facets.add_value(engine.facet_counter, name, entry_model.get(entry, decoded, name, engine.source.opts))
    end
  elseif engine.counter then
    -- a finished count shares the facet counts' fields, so this adds to them too
    facets.add(engine.counter, entry_model.flatten(entry, decoded))
  end
end

---An appended entry that misses some filter line: it still counts for a field whose own lines alone dropped it.
---@param engine JLogEngine
---@param ctx JLogMatchCtx the entry's match context
M.unmatched_appended = function(engine, ctx)
  -- a finished count holds the facet fields; a query that kept it (reverse) made a facet counter it never took
  local target = engine.counting and engine.facet_counter or engine.counter

  if not target then
    return
  end
  for name, field_pred in pairs(engine.facet_preds) do
    -- into a finished count only fields it lists, as `facets.override` skipped aliased names it lacked
    if field_pred(ctx) and (engine.counting or target.fields[name]) then
      facets.add_value(target, name, ctx.get(name))
    end
  end
end

return M
