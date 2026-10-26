local chunk = require("jlog.query.chunk")
local facets = require("jlog.query.facets")
local filter = require("jlog.query.filter")
local gc = require("jlog.core.gc")
local source = require("jlog.parse.source")
local utils = require("jlog.core.utils")
local workers = require("jlog.worker")

---@class JLogScanMatch
---@field src integer source line (jsonl) or element ordinal (arrays) of the entry
---@field first integer absolute byte of its first line (jsonl), or where `source.read_elements` reads it (arrays)
---@field last integer absolute byte of its last line's end, continuation lines included, or of its element's end

---@class JLogScanJob
---@field first integer first byte
---@field last integer last byte, newline excluded
---@field next_pos integer|nil jsonl: first byte after it
---@field src integer|nil arrays: ordinal of its first element
---@field count integer|nil arrays: elements in it
---@field done boolean|nil
---@field err string|nil
---@field result string|nil the job's mpack result

---@class JLogScan
---@field index JLogPageIndex the pages scanned
---@field format JLogFormat
---@field matches JLogScanMatch[] in file order; candidates until `done` when the filter has regex terms
---@field facets JLogFacetCounter values of picked fields on every page, counted under their other filter lines
---@field facet_names table<string, boolean> the picked fields `facets` counts; one with a regex in its other lines is not
---@field done boolean
---@field fraction number how far the scan is, 0..1
---@field cancelled boolean|nil
---@field err string|nil arrays: why the text is broken, found while scanning; the matches stop there

local M = {}

-- bytes per worker job, cut at a newline; larger chunks lengthen the main thread's encode and merge
M.chunk_bytes = 1024 * 1024
-- about this many bytes are matched per step on the main thread, when workers are not used
M.main_chunk_bytes = 64 * 1024
-- tick_ns: main-thread work per tick; publish_ns: how often progress is reported
M.timing = { tick_ns = 12e6, publish_ns = 250e6 }

-- how long a scan waiting on worker threads sleeps before it checks again
local WAIT_MS = 2
-- candidates confirmed between checks of the tick's time budget
local CONFIRM_BATCH = 100
-- array elements matched between checks of the tick's time budget, when workers are not used
local MAIN_ELEMENTS = 100
-- array scans take a collector step every this many ticks: 144ms worst stalls become 111ms, for 1.5x the time
local ARRAY_GC_TICKS = 8

---The chunk starting at `pos`: about `size` bytes, ending at a newline or at the end of `text`.
---@param text string
---@param pos integer
---@param size integer
---@return JLogScanJob
local function cut_chunk(text, pos, size)
  local newline = text:find("\n", math.min(pos + size - 1, #text), true)

  if not newline then
    return { first = pos, last = #text, next_pos = #text + 1 }
  end

  return { first = pos, last = newline - 1, next_pos = newline + 1 }
end

---Stitches chunk results into matches in file order, as `source.append_lines` joins lines into entries.
---@param matches JLogScanMatch[] mutated
---@return fun(result: JLogChunkMatch)
local function merger(matches)
  local next_lnum = 1
  -- the last entry so far is JSON, and its match when it matched
  local last_json, last_open = false, nil

  return function(result)
    local offset = next_lnum - 1
    local lead, spans = result.lead, result.spans
    local match

    -- lines before the chunk's first JSON line continue a JSON entry before them, or are plain entries
    if result.lead_last > 0 and last_json then
      if last_open then
        last_open.last = result.lead_last
      end
    elseif result.lead_last > 0 then
      for at = 1, #lead, 3 do
        matches[#matches + 1] = { src = lead[at] + offset, first = lead[at + 1], last = lead[at + 2] }
      end
    end
    for at = 1, #spans, 3 do
      match = { src = spans[at] + offset, first = spans[at + 1], last = spans[at + 2] }
      matches[#matches + 1] = match
    end
    if result.last_json_src then
      last_json = true
      last_open = match and match.src == result.last_json_src + offset and match or nil
    end
    next_lnum = next_lnum + result.lines
  end
end

---The entry a match's span holds, read again from the text.
---@param text string
---@param format JLogFormat
---@param match JLogScanMatch
---@return JLogEntry
local function match_entry(text, format, match)
  local entries = {}

  if format ~= "jsonl" then
    return source.read_elements(text, match.first, 1, format, match.src)[1]
  end
  source.append_lines(entries, vim.split(text:sub(match.first, match.last), "\n", { plain = true }), match.src)

  return entries[1]
end

---Keep the candidates the full filter accepts, in ticks; the entry of each is parsed again from its span.
---@param scan JLogScan
---@param text string
---@param filters string[]
---@param opts JLogOptions
---@param on_progress fun()
---@param on_done fun()
local function confirm(scan, text, format, filters, opts, on_progress, on_done)
  local pred = filter.compile(filters)
  local ctx, set = chunk.entry_ctx(opts)
  local candidates = scan.matches
  local confirmed = {}
  local next_index = 1

  local function step()
    local deadline = utils.tick_deadline(M.timing.tick_ns)
    local match

    if scan.cancelled then
      return
    end
    repeat
      for index = next_index, math.min(next_index + CONFIRM_BATCH - 1, #candidates) do
        match = candidates[index]
        set(match_entry(text, format, match))
        if pred(ctx) then
          confirmed[#confirmed + 1] = match
        end
      end
      next_index = next_index + CONFIRM_BATCH
    until next_index > #candidates or vim.uv.hrtime() >= deadline
    -- re-parsing candidates makes garbage fast: paced, its collector cycles stall ~40ms instead of ~130ms on 100MB
    gc.step(deadline)
    scan.fraction = 0.5 + 0.5 * math.min(next_index - 1, #candidates) / math.max(#candidates, 1)
    on_progress()
    if next_index <= #candidates then
      vim.defer_fn(step, 0)

      return
    end
    scan.matches = confirmed
    on_done()
  end

  step()
end

---Scan a jsonl text: chunks matched on worker threads, or on the main thread once workers fail or stall.
---@param scan JLogScan
---@param text string
---@param filters string[]
---@param opts JLogOptions
---@param on_progress fun()
---@param on_done fun()
local function scan_lines(scan, text, filters, opts, on_progress, on_done)
  local pred, _, exact = filter.compile(filters, { defer_regex = true })
  local field_preds = chunk.field_preds(filters)
  local merge = merger(scan.matches)
  local payload_opts = { unwrap = opts.unwrap, fields = opts.fields, time_utc = opts.view.time_utc }
  -- dispatched and not yet merged, in source order
  local jobs = {}
  local cut = 1
  local fallback = false
  local progress_at = vim.uv.now()

  for name in pairs(field_preds) do
    scan.facet_names[name] = true
  end

  local function dispatch(job)
    local payload = vim.mpack.encode({
      text = text:sub(job.first, job.last),
      first_src = 1,
      first_byte = job.first,
      filters = filters,
      opts = payload_opts,
    })

    workers.run("scan_lines", payload, function(err, result)
      job.done, job.err, job.result = true, err, result
      progress_at = vim.uv.now()
    end)
    progress_at = vim.uv.now()
  end

  local function finish()
    if exact then
      scan.fraction = 1
      on_done()

      return
    end
    confirm(scan, text, "jsonl", filters, opts, on_progress, on_done)
  end

  local function step()
    local deadline = utils.tick_deadline(M.timing.tick_ns)
    local job, waiting, merged_to

    if scan.cancelled then
      return
    end
    repeat
      fallback = fallback or (not jobs[1] and not workers.available())
      if fallback then
        job, waiting = cut_chunk(text, cut, M.main_chunk_bytes), false
        cut = job.next_pos
        merge(chunk.match(text:sub(job.first, job.last), 1, job.first, pred, opts, field_preds, scan.facets))
      else
        -- the shared cap also counts jobs of a cancelled scan that are still running
        while cut <= #text and #jobs < workers.limit() and workers.in_flight() < workers.limit() do
          job = cut_chunk(text, cut, M.chunk_bytes)
          cut = job.next_pos
          jobs[#jobs + 1] = job
          dispatch(job)
        end
        job = jobs[1]
        -- no job out with text left means the cap is full of other jobs; either way this step waits on workers
        waiting = (job and not job.done) or (not job and cut <= #text)
        if job and job.done and job.err then
          -- the jobs still out are dropped; their lines are matched here
          fallback, cut, jobs = true, job.first, {}
        elseif job and job.done then
          table.remove(jobs, 1)
          job.result = vim.mpack.decode(job.result)
          facets.merge(scan.facets, job.result.values)
          merge(job.result)
        elseif waiting and vim.uv.now() - progress_at > workers.stall_ms then
          fallback, cut, jobs, waiting = true, job and job.first or cut, {}, false
        end
      end
      -- merged up to the first job still out
      merged_to = jobs[1] and jobs[1].first - 1 or cut - 1
      scan.fraction = merged_to / math.max(#text, 1) * (exact and 1 or 0.5)
    until waiting or (cut > #text and not jobs[1]) or vim.uv.hrtime() >= deadline
    on_progress()
    if cut > #text and not jobs[1] then
      finish()

      return
    end
    vim.defer_fn(step, waiting and WAIT_MS or 0)
  end

  step()
end

---Scan an array or loki text: chunks of elements matched on worker threads, or on the main thread once workers fail
---or stall; a broken array ends the scan where it breaks, with `scan.err` set.
---@param scan JLogScan
---@param index JLogPageIndex its scan done
---@param format JLogFormat
---@param filters string[]
---@param opts JLogOptions
---@param on_progress fun()
---@param on_done fun()
local function scan_elements(scan, index, format, filters, opts, on_progress, on_done)
  local text = index.text
  local chunks = index.chunks
  local total = index.total
  local pred, _, exact = filter.compile(filters, { defer_regex = true })
  local field_preds = chunk.field_preds(filters)
  local payload_opts = { unwrap = opts.unwrap, fields = opts.fields, time_utc = opts.view.time_utc }
  -- dispatched and not yet merged, in file order
  local jobs = {}
  local next_chunk = 1
  local fallback = false
  -- main thread: where the next element is read from, and its ordinal; pos is nil past the end
  local pos, src = 1, 1
  local ticks = 0
  local progress_at = vim.uv.now()

  for name in pairs(field_preds) do
    scan.facet_names[name] = true
  end

  local function add(spans)
    for at = 1, #spans, 3 do
      scan.matches[#scan.matches + 1] = { src = spans[at], first = spans[at + 1], last = spans[at + 2] }
    end
  end

  local function cut_elements(at)
    local after = chunks[at + 1]

    return {
      first = chunks[at].first,
      last = after and after.first - 1 or #text,
      src = chunks[at].element,
      count = (after and after.element or total + 1) - chunks[at].element,
    }
  end

  local function dispatch(job)
    local payload = vim.mpack.encode({
      text = text:sub(job.first, job.last),
      first_src = job.src,
      first_byte = job.first,
      count = job.count,
      format = format,
      filters = filters,
      opts = payload_opts,
    })

    workers.run("scan_elements", payload, function(err, result)
      job.done, job.err, job.result = true, err, result
      progress_at = vim.uv.now()
    end)
    progress_at = vim.uv.now()
  end

  -- the main thread goes on from the first chunk not merged; the jobs still out are dropped
  local function fall_back(job)
    local at = job or chunks[next_chunk]

    fallback, jobs = true, {}
    pos, src = at and at.first, at and (at.src or at.element)
  end

  local function finish()
    scan.fraction = exact and 1 or 0.5
    -- a broken array is read again as jsonl, so its candidates need no checking
    if exact or scan.err then
      on_done()

      return
    end
    confirm(scan, text, format, filters, opts, on_progress, on_done)
  end

  local function step()
    local deadline = utils.tick_deadline(M.timing.tick_ns)
    local job, waiting, spans, err

    if scan.cancelled then
      return
    end
    repeat
      if not fallback and not jobs[1] and not workers.available() then
        fall_back()
      end
      if fallback and pos then
        waiting = false
        spans, pos, src, err =
          chunk.match_elements(text, pos, src, MAIN_ELEMENTS, format, pred, opts, field_preds, scan.facets)
        add(spans)
        scan.err = err
        pos = not err and src <= total and pos or nil
      elseif not fallback then
        -- the shared cap also counts jobs of a cancelled scan that are still running
        while chunks[next_chunk] and #jobs < workers.limit() and workers.in_flight() < workers.limit() do
          job = cut_elements(next_chunk)
          next_chunk = next_chunk + 1
          jobs[#jobs + 1] = job
          dispatch(job)
        end
        job = jobs[1]
        waiting = (job and not job.done) or (not job and chunks[next_chunk] ~= nil)
        if job and job.done and job.err then
          fall_back(job)
        elseif job and job.done then
          table.remove(jobs, 1)
          job.result = vim.mpack.decode(job.result)
          facets.merge(scan.facets, job.result.values)
          add(job.result.spans)
          src = job.src + job.count
        elseif waiting and vim.uv.now() - progress_at > workers.stall_ms then
          fall_back(job)
          waiting = false
        end
        if not fallback and not jobs[1] and not chunks[next_chunk] then
          pos = nil
        end
      end
      scan.fraction = (src - 1) / math.max(total, 1) * (exact and 1 or 0.5)
    until waiting or not pos or vim.uv.hrtime() >= deadline
    ticks = ticks + 1
    if fallback and ticks % ARRAY_GC_TICKS == 0 then
      gc.step(deadline)
    end
    on_progress()
    if not pos then
      finish()

      return
    end
    vim.defer_fn(step, waiting and WAIT_MS or 0)
  end

  if total == 0 then
    finish()

    return
  end
  step()
end

---Find the entries of every page that match `filters`, in ticks; `on_done` is not called once cancelled.
---@param index JLogPageIndex its scan done
---@param format JLogFormat
---@param filters string[]
---@param opts JLogOptions
---@param on_progress fun(scan: JLogScan) at most every `timing.publish_ns`
---@param on_done fun(scan: JLogScan)
---@return JLogScan
M.run = function(index, format, filters, opts, on_progress, on_done)
  local scan = {
    index = index,
    format = format,
    matches = {},
    facets = facets.counter(),
    facet_names = {},
    done = false,
    fraction = 0,
  }
  local published = 0

  local function progress()
    local now = vim.uv.hrtime()

    if now - published >= M.timing.publish_ns then
      published = now
      on_progress(scan)
    end
  end

  local function done()
    if scan.cancelled then
      return
    end
    scan.done, scan.fraction = true, 1
    on_done(scan)
  end

  vim.defer_fn(function()
    if scan.cancelled then
      return
    end
    if format == "jsonl" then
      scan_lines(scan, index.text, filters, opts, progress, done)

      return
    end
    scan_elements(scan, index, format, filters, opts, progress, done)
  end, 0)

  return scan
end

---Read a done scan's matched entries in file order, in ticks, each from its span.
---@param scan JLogScan
---@param on_done fun(entries: JLogEntry[])
---@return fun() cancel
M.entries = function(scan, on_done)
  local entries = {}
  local matches = scan.matches
  local next_index = 1
  local cancelled = false

  local function step()
    local deadline = utils.tick_deadline(M.timing.tick_ns)

    if cancelled then
      return
    end
    repeat
      for index = next_index, math.min(next_index + CONFIRM_BATCH - 1, #matches) do
        entries[#entries + 1] = match_entry(scan.index.text, scan.format, matches[index])
      end
      next_index = next_index + CONFIRM_BATCH
    until next_index > #matches or vim.uv.hrtime() >= deadline
    if next_index <= #matches then
      vim.defer_fn(step, 0)

      return
    end
    on_done(entries)
  end

  vim.defer_fn(step, 0)

  return function()
    cancelled = true
  end
end

---Stop `scan`: no more work runs and `on_done` is never called; results of jobs already queued are dropped.
---@param scan JLogScan
M.cancel = function(scan)
  scan.cancelled = true
end

---How many of a scan's matches have a source position in `first..last`.
---@param scan JLogScan
---@param first integer
---@param last integer
---@return integer
M.count_between = function(scan, first, last)
  local matches = scan.matches

  ---The index of the first match whose `src` is at least `src`.
  local function lower_bound(src)
    local low, high = 1, #matches + 1
    local mid

    while low < high do
      mid = math.floor((low + high) / 2)
      if matches[mid].src < src then
        low = mid + 1
      else
        high = mid
      end
    end

    return low
  end

  return lower_bound(last + 1) - lower_bound(first)
end

---How many matches each page holds of its own entries, overlap left out.
---@param scan JLogScan
---@param index JLogPageIndex its scan done
---@return integer[]
M.page_counts = function(scan, index)
  local counts = {}
  local range

  for page = 1, index:count() or 0 do
    range = index:range(page)
    counts[page] = M.count_between(
      scan,
      range.core_first_line or range.core_first_element,
      range.core_last_line or range.core_last_element
    )
  end

  return counts
end

return M
