local config = require("jlog.config")
local detect = require("jlog.parse.detect")
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local filter = require("jlog.query.filter")
local group = require("jlog.query.group")
local pages = require("jlog.parse.pages")
local sidebar_mod = require("jlog.ui.sidebar")
local source = require("jlog.parse.source")
local view_mod = require("jlog.ui.view")

---@class JLogOpenTarget
---@field path string|nil
---@field bufnr integer|nil
---@field force boolean|nil open even when detection fails (as jsonl)

---@class JLogWorkspaceState
---@field filters string[] valid filter clauses, one per line (AND between lines)
---@field group string|nil
---@field mode JLogViewMode
---@field reverse boolean
---@field expanded table<integer, boolean> entry index -> toggled away from `mode`

---@class JLogWorkspace
---@field key string absolute path, or `"buf:" .. bufnr`
---@field path string|nil
---@field bufnr integer|nil
---@field format JLogFormat
---@field entries JLogEntry[]
---@field opts JLogOptions
---@field tab integer
---@field view JLogView
---@field sidebar JLogSidebar
---@field state JLogWorkspaceState
---@field augroup integer
---@field generation integer bumped per apply; stale chunked applies stop
---@field fields_seen table<string, boolean>
---@field published {names: integer, at: number} fields the sidebar shows from the current counter, and when
---@field closed boolean|nil
---@field size integer bytes of the file read so far (path sources)
---@field complete boolean the bytes read so far end on a newline
---@field check string last bytes read, to detect a rewritten file
---@field next_lnum integer source line number of the next appended line
---@field counter JLogFacetCounter|nil facet counts of the last apply, once complete
---@field counting JLogFacetCounting|nil the current apply's facet count, still running after its view rendered
---@field rendered integer generation of the last apply that finished rendering
---@field watcher uv.uv_fs_event_t|nil
---@field timer uv.uv_timer_t|nil debounces reloads
---@field poll uv.uv_timer_t|nil polls for the file to come back after it was deleted or rotated
---@field loading boolean|nil the rest of the source is still being parsed in chunks
---@field stored_newest_first boolean entries are kept in file order, and this file lists the newest first
---@field reload_pending boolean|nil a reload arrived while loading
---@field pages JLogPageIndex|nil nil when the source fits one page
---@field page integer|nil the page shown, 1 holding the newest entries
---@field core integer[]|nil `{ first, last }` source positions of the page's own entries; the rest is overlap
---@field indexing JLogPageIndex|nil an index still being scanned in ticks
---@field appended string[]|nil lines appended since the index was built, until it is built again
---@field load_token table|nil the page or first load running; a newer one stops it
---@field target_page integer|nil the page last asked for, which `ws.page` becomes once it has loaded
---@field shown integer entries shown by the last apply, for the winbar
local Workspace = {}
Workspace.__index = Workspace

---@class JLogFacetCounting
---@field counter JLogFacetCounter
---@field matched table<integer, boolean> entry index -> matched the apply's filters
---@field next_index integer

local M = {}

local HEAD_LIMIT = 65536
-- entries scanned between checks of the tick's time budget
local SCAN_BATCH = 500
-- entries looked at between checks of the tick's time budget while counting facets
local COUNT_BATCH = 100
local DEBOUNCE_MS = 200
local TAIL_CHECK = 256
local POLL_MS = 500
-- the default (200) pays collection debt in one 50-80ms tick at 500k lines; 400 keeps ticks under ~35ms
local GC_STEPMUL = 400

-- lines or array elements parsed before the first screen, and later between checks of the tick's time budget
M.load_sizes = { first = 2000, chunk = 500 }
-- tick_ns: work per tick before yielding (keeps ticks ~16ms); publish_ns: how often new fields reach the sidebar
M.timing = { tick_ns = 12e6, publish_ns = 250e6 }
-- how long open may index to find page 1 before its first screen
M.open_index_ns = 150e6

---@type table<string, JLogWorkspace>
local registry = {}

-- shortcut: a sync read of 100MB takes tens of ms; read async if that ever matters
---@param path string
---@return string|nil
---@return string|nil err
-- the user's stepmul while any workspace is open, nil otherwise
local saved_stepmul

---Collect in smaller, steadier steps while a workspace exists: GC settings are global, so only then.
local function tune_gc()
  if saved_stepmul == nil then
    -- selene: allow(incorrect_standard_library_use)
    saved_stepmul = collectgarbage("setstepmul", GC_STEPMUL)
  end
end

---Give the user's stepmul back once the last workspace is gone.
local function restore_gc()
  if saved_stepmul ~= nil and next(registry) == nil then
    -- selene: allow(incorrect_standard_library_use)
    collectgarbage("setstepmul", saved_stepmul)
    saved_stepmul = nil
  end
end

local function read_file(path)
  local fd, err = vim.uv.fs_open(path, "r", 438)
  local stat, data

  if not fd then
    return nil, err
  end
  stat, err = vim.uv.fs_fstat(fd)
  if stat then
    data, err = vim.uv.fs_read(fd, stat.size, 0)
  end
  vim.uv.fs_close(fd)

  return data, err
end

---@param path string|nil
---@param bufnr integer|nil
---@return string|nil
---@return string|nil err
local function read_source(path, bufnr)
  if path then
    return read_file(path)
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "no file or valid buffer to open"
  end

  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

---An empty, unmodified buffer, unnamed or named after the file (e.g. a buffer for a file that did not exist yet).
---@param bufnr integer
---@param path string|nil
---@return boolean
local function is_placeholder(bufnr, path)
  local name = vim.api.nvim_buf_get_name(bufnr)

  return (name == "" or name == path)
    and not vim.bo[bufnr].modified
    and vim.api.nvim_buf_line_count(bufnr) == 1
    and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ""
end

---Wipe empty, unmodified buffers named `path`: `:tabedit` would reuse one unread and `:w` would truncate the file.
---@param path string
local function wipe_placeholders(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_get_name(bufnr) == path
      and vim.api.nvim_buf_is_loaded(bufnr)
      and is_placeholder(bufnr, path)
    then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

---@param ws JLogWorkspace
---@param bufnr integer
---@return integer|nil
local function window_in_tab(ws, bufnr)
  if not vim.api.nvim_tabpage_is_valid(ws.tab) then
    return nil
  end
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(ws.tab)) do
    if vim.api.nvim_win_get_buf(winid) == bufnr then
      return winid
    end
  end

  return nil
end

---@param ws JLogWorkspace
---@return integer winid
local function open_sidebar_window(ws)
  local winid = vim.api.nvim_open_win(ws.sidebar.bufnr, false, {
    split = ws.opts.sidebar.position,
    win = window_in_tab(ws, ws.view.bufnr) or vim.api.nvim_tabpage_get_win(ws.tab),
    width = ws.opts.sidebar.width,
  })
  local wo = vim.wo[winid][0]

  wo.number = false
  wo.relativenumber = false
  wo.wrap = false
  wo.winfixwidth = true

  return winid
end

---@param ws JLogWorkspace
---@param path string|nil
local function create_layout(ws, path)
  local current_win = vim.api.nvim_get_current_win()
  local reuse = #vim.api.nvim_tabpage_list_wins(0) == 1 and is_placeholder(vim.api.nvim_win_get_buf(current_win), path)
  local view_win

  if not reuse then
    vim.cmd("tabnew")
  end
  -- wipe the empty buffer once the view replaces it: a kept one would let `:tabedit` then `:w` truncate the file
  vim.bo.bufhidden = "wipe"
  ws.tab = vim.api.nvim_get_current_tabpage()
  view_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(view_win, ws.view.bufnr)
  open_sidebar_window(ws)
  vim.api.nvim_set_current_win(view_win)
end

---@param lines string[]
---@param errors {lnum: integer, msg: string}[]
---@return string[] valid
---@return JLogFilterError[] invalid
local function split_invalid(lines, errors)
  local bad = {}
  local valid = {}
  local invalid = {}

  for _, err in ipairs(errors) do
    bad[err.lnum] = err.msg
  end
  for lnum, line in ipairs(lines) do
    if bad[lnum] then
      invalid[#invalid + 1] = { text = line, msg = bad[lnum] }
    elseif line:find("%S") then
      valid[#valid + 1] = line
    end
  end

  return valid, invalid
end

---@param ws JLogWorkspace
---@param shown integer
---@return string
local function winbar_text(ws, shown)
  local parts = { "jlog", ws.format, shown .. "/" .. #ws.entries }

  if ws.pages and ws.page then
    parts[#parts + 1] = "page " .. ws.page .. "/" .. (ws.pages:count() or "…")
  end
  if #ws.state.filters > 0 then
    parts[#parts + 1] = table.concat(ws.state.filters, " · ")
  end
  if ws.state.group then
    parts[#parts + 1] = "group: " .. ws.state.group
  end

  return table.concat(parts, " · ")
end

---@param ws JLogWorkspace
---@param counter JLogFacetCounter
local function publish_facets(ws, counter)
  ws.sidebar.facets = facets.result(counter, ws.opts.facets.top_values)
  for _, facet in ipairs(ws.sidebar.facets) do
    ws.fields_seen[facet.name] = true
  end
  ws.published.names = #counter.names
end

---Show newly found fields while a load or apply runs, at most every `timing.publish_ns`; unsaved edits are kept.
---@param ws JLogWorkspace
---@param counter JLogFacetCounter
---@param progress string
local function publish_partial(ws, counter, progress)
  local now = vim.uv.hrtime()

  -- a counter only gains names, so a count above the published one means new fields
  if #counter.names <= ws.published.names or now - ws.published.at < M.timing.publish_ns then
    return
  end
  if not window_in_tab(ws, ws.sidebar.bufnr) or vim.bo[ws.sidebar.bufnr].modified then
    return
  end
  ws.published.at = now
  publish_facets(ws, counter)
  ws.sidebar:render(progress)
end

---Count the facets of the matched entries in ticks after the view is shown, then publish; a newer apply stops it.
---@param ws JLogWorkspace
---@param generation integer the apply that set up `ws.counting`
local function count_facets(ws, generation)
  local deadline = vim.uv.hrtime() + M.timing.tick_ns
  local entries = ws.entries
  local counting, last, entry

  if ws.closed or ws.generation ~= generation then
    return
  end
  counting = ws.counting
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
    vim.defer_fn(function()
      count_facets(ws, generation)
    end, 0)

    return
  end

  ws.counting = nil
  ws.counter = counting.counter
  ws.sidebar.stale = false
  publish_facets(ws, counting.counter)
  -- unsaved FILTERS edits are kept; the next sync renders the counts
  if not vim.bo[ws.sidebar.bufnr].modified then
    ws.sidebar:render()
  end
end

---Filter, group and render, then count facets; work past the first ~12ms tick continues later, a newer apply wins.
---@param on_done fun()|nil called once the view has rendered
---@param counted JLogFacetCounter|nil facets of every entry, counted while loading; used when no filter applies
Workspace.apply = function(self, on_done, counted)
  local generation = self.generation + 1
  local entries, opts, state = self.entries, self.opts, self.state
  local count = #entries
  local field = state.group and filter.unescape_field(state.group)
  local counts = window_in_tab(self, self.sidebar.bufnr) ~= nil
  local matched = {}
  local group_values = {}
  local summary_values = {}
  local lines = vim.deepcopy(state.filters)
  local pred, errors, invalid
  local entry, decoded, decoded_done
  local next_index = 1
  local prefilled, collected
  local cursor_entry

  self.generation = generation
  for _, name in ipairs(group.SUMMARY_FIELDS) do
    summary_values[name] = {}
  end
  -- lines that failed before stay pending until edited, so re-validate them with the rest
  for _, err in ipairs(self.sidebar.errors) do
    lines[#lines + 1] = err.text
  end
  pred, errors = filter.compile(lines)
  state.filters, invalid = split_invalid(lines, errors)
  self.sidebar:set_errors(invalid)
  -- every entry matches, so the load's counts are this apply's counts
  prefilled = counts and counted ~= nil and #state.filters == 0
  self.counter = prefilled and counted or nil
  self.counting = nil
  -- the sidebar keeps the last counts until this apply's are counted
  self.sidebar.stale = counts and not prefilled
  if self.sidebar.stale then
    self.sidebar:render()
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
  local ctx = { raw = "", get = read }

  local function scan(first, last)
    for index = first, last do
      entry, decoded_done = entries[index], false
      ctx.raw = entry_model.key(entry)
      if pred(ctx) then
        matched[index] = true
      end
      if field then
        group_values[index] = read(field)
        -- read now, in the time-boxed scan: decoding again while building groups is one long tick
        for name, values in pairs(summary_values) do
          values[index] = read(name)
        end
      end
    end
    entry, decoded = nil, nil
  end

  local function publish(items, shown)
    if prefilled then
      publish_facets(self, counted)
    end
    self.shown = shown
    self.view:set_winbar(winbar_text(self, shown))
    self.sidebar:render()
    self.view:render(items, function()
      -- a newer apply that has not rendered yet supersedes this render too
      if self.generation ~= generation or self.closed then
        return
      end
      self.rendered = generation
      if cursor_entry then
        self.view:goto_entry(cursor_entry)
      end
      -- set up now so appends join it; counting starts in a tick of its own
      if self.sidebar.stale then
        self.counting = { counter = facets.counter(), matched = matched, next_index = 1 }
        vim.defer_fn(function()
          count_facets(self, generation)
        end, 0)
      end
      if on_done then
        on_done()
      end
    end)
  end

  -- group.build in a coroutine that yields when the tick is up; a build spanning ticks publishes in a tick of its own
  local function finish()
    local build_deadline
    local build = coroutine.create(function()
      return group.build(count, {
        pred = function(index)
          return matched[index] == true
        end,
        field = field,
        reverse = state.reverse,
        newest_first = self.stored_newest_first,
        get = function(index, path)
          return (path == field and group_values or summary_values[path])[index]
        end,
        checkpoint = function()
          if vim.uv.hrtime() >= build_deadline then
            coroutine.yield()
          end
        end,
      })
    end)
    local yielded = false

    cursor_entry = self.view:entry_at_cursor()

    local function resume()
      local ok, items, shown

      if self.generation ~= generation or self.closed then
        return
      end
      build_deadline = vim.uv.hrtime() + M.timing.tick_ns
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
        publish(items, shown)

        return
      end
      vim.defer_fn(function()
        if self.generation == generation and not self.closed then
          publish(items, shown)
        end
      end, 0)
    end

    resume()
  end

  ---@param sync boolean|nil the first tick, run by apply itself: work that fits in it finishes at once
  local function step(sync)
    local deadline = vim.uv.hrtime() + M.timing.tick_ns
    local last

    if self.generation ~= generation or self.closed then
      return
    end
    repeat
      last = math.min(next_index + SCAN_BATCH - 1, count)
      scan(next_index, last)
      next_index = last + 1
    until next_index > count or vim.uv.hrtime() >= deadline
    if next_index > count and sync then
      finish()

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
        if self.generation == generation and not self.closed then
          finish()
        end
      end, 0)

      return
    end
    self.view:set_winbar("jlog · applying " .. math.floor(last * 100 / count) .. "%")
    -- a timer, not vim.schedule: chained scheduled callbacks run back to back without handling input or redraw
    vim.defer_fn(step, 0)
  end

  step(true)
end

---@param clause string
Workspace.add_filter = function(self, clause)
  table.insert(self.state.filters, clause)
  self:apply()
end

Workspace.clear_filters = function(self)
  self.state.filters = {}
  self.sidebar:set_errors({})
  self:apply()
end

---@param field string|nil nil clears the group
Workspace.set_group = function(self, field)
  self.state.group = field ~= "" and field or nil
  self:apply()
end

-- shortcut: re-runs the whole apply; keep the last matches if reversing 500k entries feels slow
Workspace.toggle_reverse = function(self)
  self.state.reverse = not self.state.reverse
  self:apply()
end

Workspace.focus_sidebar = function(self)
  local winid = window_in_tab(self, self.sidebar.bufnr)

  if not winid then
    winid = open_sidebar_window(self)
    -- facets are skipped while the sidebar is hidden
    self:apply()
  end
  vim.api.nvim_set_current_win(winid)
end

Workspace.toggle_sidebar = function(self)
  local winid = window_in_tab(self, self.sidebar.bufnr)

  if not winid then
    open_sidebar_window(self)
    self:apply()

    return
  end
  pcall(vim.api.nvim_win_close, winid, false)
end

---@param ws JLogWorkspace
---@param text string
local function snapshot(ws, text)
  local newlines, pos = 0, 0

  ws.size = #text
  ws.complete = text == "" or text:sub(-1) == "\n"
  ws.check = text:sub(-TAIL_CHECK)
  while true do
    pos = text:find("\n", pos + 1, true)
    if not pos then
      break
    end
    newlines = newlines + 1
  end
  ws.next_lnum = newlines + 1
end

---The new complete lines of a jsonl file that only grew, or nil when it must be rebuilt; a partial last line waits.
---@param ws JLogWorkspace
---@return string|nil
local function read_appended(ws)
  local fd = vim.uv.fs_open(ws.path, "r", 438)
  local stat, check_len, tail, last_newline

  if not fd then
    return nil
  end
  stat = vim.uv.fs_fstat(fd)
  if stat and stat.size > ws.size and ws.complete then
    check_len = math.min(TAIL_CHECK, ws.size)
    if vim.uv.fs_read(fd, check_len, ws.size - check_len) == ws.check then
      tail = vim.uv.fs_read(fd, stat.size - ws.size, ws.size)
    end
  end
  vim.uv.fs_close(fd)
  if not tail then
    return nil
  end
  last_newline = tail:match(".*()\n")

  return last_newline and tail:sub(1, last_newline) or ""
end

---Show the new entries `from..` in a flat view without a full apply. Returns false when an apply is needed.
---@param ws JLogWorkspace
---@param old_count integer entry count before the append
---@param old_key string|nil key of the last old entry before the append
---@return boolean
local function extend_view(ws, old_count, old_key)
  local entries, view, counter, counting = ws.entries, ws.view, ws.counter, ws.counting
  local pred = filter.compile(ws.state.filters)
  local changed = old_key ~= nil and entry_model.key(entries[old_count]) ~= old_key
  local indexes = {}
  local refresh, entry, decoded, shown, matches
  local ctx = {
    get = function(path)
      return entry_model.get(entry, decoded, path, ws.opts)
    end,
  }

  for index = changed and old_count or old_count + 1, #entries do
    entry = entries[index]
    decoded = entry_model.decode(entry)
    ctx.raw = entry_model.key(entry)
    matches = pred(ctx)
    shown = view.entry_item[index] ~= nil
    if shown and not matches then
      return false
    end
    if shown then
      refresh = index
    elseif matches then
      indexes[#indexes + 1] = index
    end
    -- a count still running takes new matches into its pass
    if matches and counting and index > old_count then
      counting.matched[index] = true
    elseif matches and counter and index > old_count then
      facets.add(counter, entry_model.flatten(entry, decoded))
    end
  end

  if ws.state.reverse then
    view:prepend(vim.fn.reverse(indexes), refresh)
  else
    view:append(indexes, refresh)
  end
  ws.shown = #view.items
  view:set_winbar(winbar_text(ws, ws.shown))
  if counter then
    publish_facets(ws, counter)
    ws.sidebar:render()
  end

  return true
end

---@param view JLogView
---@param index integer entry index to land on, or the nearest one that is shown
local function goto_nearest(view, index)
  for distance = 0, #view.ws.entries do
    for _, candidate in ipairs({ index - distance, index + distance }) do
      if view.entry_item[candidate] then
        view:goto_entry(candidate)

        return
      end
    end
  end
end

---Swap in rebuilt entries, keeping state: expanded entries and the cursor entry are found again by key.
---@param ws JLogWorkspace
---@param entries JLogEntry[]
local function replace_entries(ws, entries)
  local old, state = ws.entries, ws.state
  local cursor = ws.view:entry_at_cursor()
  local cursor_key = cursor and entry_model.key(old[cursor])
  local new_index, expanded = {}, {}
  local entry_key, target

  if cursor_key or next(state.expanded) then
    for index, entry in ipairs(entries) do
      entry_key = entry_model.key(entry)
      new_index[entry_key] = new_index[entry_key] or index
    end
  end
  for index in pairs(state.expanded) do
    target = new_index[entry_model.key(old[index])]
    if target then
      expanded[target] = true
    end
  end
  state.expanded = expanded
  ws.entries = entries
  cursor = cursor_key and new_index[cursor_key] or cursor
  ws:apply(function()
    if cursor then
      goto_nearest(ws.view, cursor)
    end
  end)
end

---@param text string
---@param pos integer
---@param count integer
---@param stop integer last byte to read
---@return string[] lines
---@return integer next_pos
local function take_lines(text, pos, count, stop)
  local lines = {}
  local newline

  for _ = 1, count do
    if pos > stop then
      break
    end
    newline = text:find("\n", pos, true)
    if not newline then
      lines[#lines + 1] = text:sub(pos)
      pos = #text + 1

      break
    end
    lines[#lines + 1] = text:sub(pos, newline - 1)
    pos = newline + 1
  end

  return lines, pos
end

---Reads `count` more units (default `load_sizes.chunk`) into `entries`; returns the fraction read, nil when done.
---@alias JLogReader fun(entries: JLogEntry[], on_json: function|nil, count: integer|nil): number|nil

---@param text string
---@param pos integer byte position of the next unparsed line
---@param lnum integer source line number of that line
---@param stop integer last byte to read
---@return JLogReader
local function line_reader(text, pos, lnum, stop)
  local start = pos

  return function(entries, on_json, count)
    local lines

    lines, pos = take_lines(text, pos, count or M.load_sizes.chunk, stop)
    source.append_lines(entries, lines, lnum, on_json)
    lnum = lnum + #lines

    return pos <= stop and (pos - start) / (stop - start + 1) or nil
  end
end

---A broken array keeps what was read; the unparsed rest follows as plain entries, one per line.
---@param entries JLogEntry[] mutated
---@param text string
---@param rest_at integer where the unparsed rest starts
---@param stop integer last byte of the rest
---@param err string
local function keep_broken_rest(entries, text, rest_at, stop, err)
  vim.notify("jlog: broken JSON array: " .. err .. "; the rest is shown as plain lines", vim.log.levels.WARN)
  source.append_plain(entries, text:sub(rest_at, stop))
end

---@param text string
---@param pos integer|nil where `source.read_elements` goes on; nil when nothing is left
---@param format JLogFormat
---@param first_src integer ordinal of the element at `pos`
---@param last_src integer|nil ordinal of the last element to read; nil reads to the end of the array
---@param stop integer last byte to read
---@return JLogReader
local function element_reader(text, pos, format, first_src, last_src, stop)
  local start = pos

  return function(entries, on_json, count)
    local wanted = math.min(count or M.load_sizes.chunk, (last_src or math.huge) - first_src + 1 - #entries)
    local chunk, next_pos, err

    if not pos or wanted <= 0 or (#entries == 0 and not text:find("%S")) then
      return nil
    end
    chunk, next_pos, err = source.read_elements(text, pos, wanted, format, first_src + #entries, on_json)
    vim.list_extend(entries, chunk)
    pos = not err and next_pos or nil
    if err then
      keep_broken_rest(entries, text, next_pos, stop, err)

      return nil
    end

    return pos and (pos - start) / (stop - start + 1) or nil
  end
end

---Parse the rest of the source into `entries` in chunks across event-loop ticks, then call `on_done` once.
---@param ws JLogWorkspace
---@param entries JLogEntry[] mutated
---@param read JLogReader
---@param on_done fun(entries: JLogEntry[])
---@param counter JLogFacetCounter|nil counts the facets of the loaded JSON entries, from the load's own decode
---@param token table|nil the load stops, dropping what it read, once `ws.load_token` is another load's
local function load_rest(ws, entries, read, on_done, counter, token)
  local deadline = vim.uv.hrtime() + M.timing.tick_ns
  local fraction, progress
  local count_entry = counter
    and function(entry, decoded)
      facets.add(counter, entry_model.flatten(entry, decoded))
    end

  if ws.closed or (token and ws.load_token ~= token) then
    return
  end
  repeat
    fraction = read(entries, count_entry)
  until not fraction or vim.uv.hrtime() >= deadline
  if fraction then
    progress = "loading " .. math.floor(fraction * 100) .. "%"
    ws.view:set_winbar("jlog · " .. progress)
    -- with a filter set, the sidebar shows the filtered counts of the last apply instead
    if counter and #ws.state.filters == 0 then
      publish_partial(ws, counter, progress)
    end
    vim.defer_fn(function()
      load_rest(ws, entries, read, on_done, counter, token)
    end, 0)

    return
  end

  ws.loading = nil
  on_done(entries)
  if ws.reload_pending then
    ws.reload_pending = nil
    ws:reload()
  end
end

---Stable merge sort of `list` in place; `checkpoint` is called every few thousand moves and may yield.
---@param list JLogEntry[]
---@param less fun(left: JLogEntry, right: JLogEntry): boolean
---@param checkpoint fun()
local function merge_sort(list, less, checkpoint)
  local count = #list
  local from, to = list, {}
  local width = 1
  local middle, last, left, right

  while width < count do
    for start = 1, count, 2 * width do
      middle = math.min(start + width, count + 1)
      last = math.min(start + 2 * width, count + 1)
      left, right = start, middle
      for slot = start, last - 1 do
        if left < middle and (right >= last or not less(from[right], from[left])) then
          to[slot] = from[left]
          left = left + 1
        else
          to[slot] = from[right]
          right = right + 1
        end
        if slot % 4096 == 0 then
          checkpoint()
        end
      end
    end
    from, to = to, from
    width = width * 2
  end
  if from ~= list then
    for slot = 1, count do
      list[slot] = from[slot]
    end
  end
end

---Wrap a loki reader: once everything is read, sort by timestamp, a tick's budget at a time.
---@param read JLogReader
---@return JLogReader
local function sorting_reader(read)
  local sorter, deadline
  local function checkpoint()
    if vim.uv.hrtime() >= deadline then
      coroutine.yield()
    end
  end

  return function(entries, on_json, count)
    local fraction

    -- read again after the end, as a load started after a first read that finished everything does
    if sorter and coroutine.status(sorter) == "dead" then
      return nil
    end
    if not sorter then
      fraction = read(entries, on_json, count)
      if fraction then
        return fraction
      end
      sorter = coroutine.create(function()
        merge_sort(entries, source.older_first, checkpoint)
      end)
    end
    deadline = vim.uv.hrtime() + M.timing.tick_ns
    assert(coroutine.resume(sorter))

    return coroutine.status(sorter) ~= "dead" and 1 or nil
  end
end

---The reader for an array file; an unordered loki export is sorted once read, everything else keeps file order.
---@param text string
---@param format JLogFormat
---@param order "asc"|"desc"|"none"
---@return JLogReader
local function source_reader(text, format, order)
  local read

  if format == "jsonl" then
    return line_reader(text, 1, 1, #text)
  end
  read = element_reader(text, 1, format, 1, nil, #text)

  return (format == "loki" and order == "none") and sorting_reader(read) or read
end

---@param text string
---@param pos integer
---@return integer start first byte of the line holding `pos`
local function line_start(text, pos)
  while pos > 1 and text:byte(pos - 1) ~= 10 do
    pos = pos - 1
  end

  return pos
end

---A reader of the last `count` lines of a jsonl page that ends the file: the top of a newest-first view.
---@param text string
---@param range JLogPageRange
---@param count integer
---@return JLogReader
local function tail_reader(text, range, count)
  local lnum = range.core_last_line
  local target = math.max(range.first_src, lnum - count + 1)
  local start = line_start(text, text:byte(range.last) == 10 and range.last - 1 or range.last)

  while lnum > target do
    start, lnum = line_start(text, start - 1), lnum - 1
  end

  return line_reader(text, start, lnum, range.last)
end

---@param text string
---@param format JLogFormat
---@param range JLogPageRange
---@return JLogReader
local function page_reader(text, format, range)
  if format == "jsonl" then
    return line_reader(text, range.first, range.first_src, range.last)
  end

  -- the first element is read from the array's `[`
  return element_reader(
    text,
    range.first_src == 1 and 1 or range.first,
    format,
    range.first_src,
    range.last_src,
    range.last
  )
end

---Record whether the loaded file lists the newest first; a toggled sort stays toggled.
---@param ws JLogWorkspace
---@param order "asc"|"desc"|"none"
local function set_stored_order(ws, order)
  if (order == "desc") ~= ws.stored_newest_first then
    ws.stored_newest_first = order == "desc"
    ws.state.reverse = not ws.state.reverse
  end
end

---A page index over `text`, or nil for an unordered loki export, which is sorted whole instead.
---@param text string
---@param format JLogFormat
---@param order "asc"|"desc"|"none"
---@param opts JLogOptions
---@return JLogPageIndex|nil
local function new_index(text, format, order, opts)
  if format == "loki" and order == "none" then
    return nil
  end

  return pages.new(text, format, opts.paging, (opts.view.sort == "desc") ~= (order == "desc"))
end

---Whether `index` has more than one page, or nil while that is not known yet.
---@param index JLogPageIndex
---@return boolean|nil
local function is_paged(index)
  if index:count() == 1 then
    return false
  end

  return index:known() >= 1 or nil
end

---@param range JLogPageRange
---@return integer[]
local function core_of(range)
  return {
    range.core_first_line or range.core_first_element,
    range.core_last_line or range.core_last_element,
  }
end

---The page shown holds the end of the source, where appended lines go.
---@param ws JLogWorkspace
---@return boolean
local function holds_end(ws)
  return ws.page == (ws.pages.from_end and 1 or ws.pages:count())
end

---@param ws JLogWorkspace
local function refresh_winbar(ws)
  if not ws.loading and ws.rendered == ws.generation then
    ws.view:set_winbar(winbar_text(ws, ws.shown))
  end
end

---Finish a collector cycle in time-boxed steps, or a replaced ~100MB text is collected in one long tick.
---@param ws JLogWorkspace
---@param on_done fun()|nil
local function collect(ws, on_done)
  local deadline = vim.uv.hrtime() + M.timing.tick_ns
  local collected

  if ws.closed then
    return
  end
  repeat
    -- selene: allow(incorrect_standard_library_use)
    collected = collectgarbage("step", 0)
  until collected or vim.uv.hrtime() >= deadline
  if collected then
    if on_done then
      vim.defer_fn(on_done, 0)
    end

    return
  end
  vim.defer_fn(function()
    collect(ws, on_done)
  end, 0)
end

---Scan `index` in ticks while it is `ws.indexing`; `on_known(paged)` runs once paging is known (or done: `wait_done`).
---@param ws JLogWorkspace
---@param index JLogPageIndex
---@param on_known fun(paged: boolean)|nil
---@param wait_done boolean|nil
local function scan_pages(ws, index, on_known, wait_done)
  local done

  if ws.closed or ws.indexing ~= index then
    return
  end
  done = index:scan(vim.uv.hrtime() + M.timing.tick_ns)
  if on_known and (done or (not wait_done and is_paged(index))) then
    on_known(is_paged(index) == true)
    on_known = nil
  end
  if not done then
    vim.defer_fn(function()
      scan_pages(ws, index, on_known, wait_done)
    end, 0)

    return
  end
  ws.indexing = nil
  -- an index rebuilt after an append replaces the one in use
  if ws.pages and ws.pages ~= index then
    ws.pages = index
    collect(ws)
  end
  refresh_winbar(ws)
end

---Load page `page` of `ws.pages` in ticks, then show it; `keep` keeps the cursor entry and expanded entries by key.
---@param ws JLogWorkspace
---@param page integer
---@param keep boolean|nil
local function load_page(ws, page, keep)
  local range = ws.pages:range(page)
  local read = page_reader(ws.pages.text, ws.format, range)
  local counter = facets.counter()
  local token = {}

  ws.loading, ws.load_token, ws.target_page = true, token, page
  vim.defer_fn(function()
    load_rest(ws, {}, read, function(loaded)
      local winid

      ws.page, ws.core = page, core_of(range)
      if keep then
        replace_entries(ws, loaded)

        return
      end
      ws.state.expanded = {}
      ws.entries = loaded
      ws:apply(function()
        winid = vim.fn.bufwinid(ws.view.bufnr)
        if winid ~= -1 then
          vim.api.nvim_win_set_cursor(winid, { 1, 0 })
        end
      end, counter)
    end, counter, token)
  end, 0)
end

---The page whose own entries hold source position `src`, else 1.
---@param index JLogPageIndex
---@param src integer|nil
---@return integer
local function page_holding(index, src)
  local core

  for page = 1, src and index:count() or 0 do
    core = core_of(index:range(page))
    if src >= core[1] and src <= core[2] then
      return page
    end
  end

  return 1
end

---Show page `page`, keeping filters, group and mode; false when that page is not indexed (yet).
---@param page integer
---@return boolean
Workspace.goto_page = function(self, page)
  local range = self.pages and page % 1 == 0 and self.pages:range(page)

  if not range then
    vim.notify("jlog: " .. (self.indexing and "still indexing pages" or ("no page " .. page)), vim.log.levels.WARN)

    return false
  end
  -- a page load still running is dropped for this one
  load_page(self, page)

  return true
end

---Index the text again with the lines appended since, in a tick of its own: joining ~100MB takes ~20ms.
---@param ws JLogWorkspace
local function reindex(ws)
  local base = ws.indexing or ws.pages
  local index

  -- shortcut: the whole text is indexed again per append; extend the index in place if appends get frequent
  if ws.closed or not ws.appended or not base then
    return
  end
  index = pages.new(base.text .. table.concat(ws.appended), ws.format, ws.opts.paging, base.from_end)
  ws.appended = nil
  ws.indexing = index
  vim.defer_fn(function()
    scan_pages(ws, index)
  end, 0)
end

---Re-read a rewritten source and index it again; a paged one returns to the page holding the cursor entry.
---@param ws JLogWorkspace
local function rebuild(ws)
  local text, err = read_source(ws.path, ws.bufnr)
  local order, index

  if err then
    -- a missing file is reported by the watcher, which waits for it to come back
    if not ws.path or vim.uv.fs_stat(ws.path) then
      vim.notify("jlog: cannot reload: " .. tostring(err), vim.log.levels.WARN)
    end

    return
  end
  if ws.path then
    snapshot(ws, text)
  end
  order = source.element_order(text, ws.format)
  index = new_index(text, ws.format, order, ws.opts)
  ws.indexing, ws.appended = index, nil
  -- parsed in chunks like at open; the old entries stay shown until the new ones are complete
  ws.loading = true

  local function on_known(paged)
    local cursor = ws.view:entry_at_cursor()

    set_stored_order(ws, order)
    if paged then
      ws.pages = index
      load_page(ws, page_holding(index, cursor and ws.entries[cursor].src), true)

      return
    end
    ws.pages, ws.page, ws.core, ws.target_page = nil, nil, nil, nil
    vim.defer_fn(function()
      load_rest(ws, {}, source_reader(text, ws.format, order), function(loaded)
        replace_entries(ws, loaded)
      end)
    end, 0)
  end

  if not index then
    on_known(false)

    return
  end
  vim.defer_fn(function()
    scan_pages(ws, index, on_known, true)
  end, 0)
end

---Pick up changes to the source: a grown jsonl file only parses its new lines; anything else is rebuilt.
Workspace.reload = function(self)
  local tail, old_count, old_key, shown

  if self.closed then
    return
  end
  if self.loading then
    self.reload_pending = true

    return
  end
  tail = self.path and self.format == "jsonl" and read_appended(self) or nil
  if not tail then
    rebuild(self)

    return
  end
  -- appended lines belong to the page holding the end of the file; another page stays as it is
  shown = not self.pages or holds_end(self)
  old_count = #self.entries
  old_key = old_count > 0 and entry_model.key(self.entries[old_count]) or nil
  if shown then
    source.append_lines(self.entries, vim.split(tail:sub(1, -2), "\n", { plain = true }), self.next_lnum)
  end
  self.size = self.size + #tail
  self.check = (self.check .. tail):sub(-TAIL_CHECK)
  self.next_lnum = self.next_lnum + select(2, tail:gsub("\n", ""))
  if tail == "" then
    return
  end
  if self.pages then
    if not self.appended then
      self.appended = {}
      vim.defer_fn(function()
        collect(self, function()
          reindex(self)
        end)
      end, 0)
    end
    self.appended[#self.appended + 1] = tail
    if shown then
      self.core[2] = self.next_lnum - 1
    end
  end
  if not shown then
    return
  end
  if self.state.group or self.rendered ~= self.generation or not extend_view(self, old_count, old_key) then
    self:apply()
  end
end

---@param ws JLogWorkspace
local function debounce(ws)
  ws.timer:stop()
  ws.timer:start(
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      ws:reload()
    end)
  )
end

---@param ws JLogWorkspace
local function watch_file(ws)
  local on_event, wait_for_file

  -- watch `ws.path`; while it is missing, poll until it comes back
  local function arm()
    local ok, err = ws.watcher:start(ws.path, {}, vim.schedule_wrap(on_event))

    if ok then
      return
    end
    if vim.uv.fs_stat(ws.path) then
      vim.notify("jlog: cannot watch " .. ws.path .. ": " .. tostring(err), vim.log.levels.WARN)

      return
    end
    wait_for_file()
  end

  wait_for_file = function()
    ws.poll:start(
      POLL_MS,
      POLL_MS,
      vim.schedule_wrap(function()
        if ws.closed or not vim.uv.fs_stat(ws.path) then
          return
        end
        ws.poll:stop()
        arm()
        debounce(ws)
      end)
    )
  end

  on_event = function(_, _, events)
    -- events queued before the watcher stopped can still arrive while waiting for the file
    if ws.closed or ws.poll:is_active() then
      return
    end
    -- an atomic save, a rotation or a delete: the handle still watches the old file
    if events and events.rename then
      ws.watcher:stop()
      if not vim.uv.fs_stat(ws.path) then
        vim.notify("jlog: " .. ws.path .. " is gone, waiting for it to come back", vim.log.levels.WARN)
        wait_for_file()

        return
      end
      arm()
    end
    debounce(ws)
  end

  ws.watcher = vim.uv.new_fs_event()
  ws.poll = vim.uv.new_timer()
  arm()
end

---@param ws JLogWorkspace
local function watch_buffer(ws)
  vim.api.nvim_buf_attach(ws.bufnr, false, {
    on_lines = function()
      if ws.closed then
        return true
      end
      debounce(ws)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = ws.augroup,
    buffer = ws.bufnr,
    callback = function()
      debounce(ws)
    end,
  })
end

---Close the workspace tab, wipe its buffers and forget it. Also runs when its tab is closed some other way.
Workspace.close = function(self)
  if self.closed then
    return
  end
  self.closed = true
  registry[self.key] = nil
  restore_gc()
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  -- buffer sources have no watcher or poll timer
  for _, handle in ipairs({ self.timer, self.watcher, self.poll }) do
    handle:stop()
    handle:close()
  end

  if vim.api.nvim_buf_is_valid(self.sidebar.bufnr) then
    vim.bo[self.sidebar.bufnr].modified = false
  end
  if vim.api.nvim_tabpage_is_valid(self.tab) and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd.tabclose, vim.api.nvim_tabpage_get_number(self.tab))
  end
  for _, bufnr in ipairs({ self.view.bufnr, self.sidebar.bufnr }) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

---Field paths seen in facets so far, for completion.
---@return string[]
Workspace.field_names = function(self)
  local names = vim.tbl_keys(self.fields_seen)

  table.sort(names)

  return names
end

---Open the source as a normal buffer in a new tab, at `lnum`. The only way jlog opens a raw file.
---@param lnum integer|nil
Workspace.open_raw = function(self, lnum)
  local ok, err

  if self.path then
    wipe_placeholders(self.path)
    ok, err = pcall(vim.cmd.tabedit, vim.fn.fnameescape(self.path))
  else
    ok, err = pcall(vim.cmd, "tab sbuffer " .. self.bufnr)
  end
  if not ok then
    vim.notify("jlog: " .. tostring(err), vim.log.levels.ERROR)

    return
  end
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
  end
end

---@param key string
---@return JLogWorkspace|nil
M.find = function(key)
  return registry[key]
end

---The workspace shown in the current tab.
---@return JLogWorkspace|nil
M.current = function()
  local tab = vim.api.nvim_get_current_tabpage()

  for _, ws in pairs(registry) do
    if ws.tab == tab then
      return ws
    end
  end

  return nil
end

---Load the rest of the first page, or of a source that is not paged, after the first screen.
---@param ws JLogWorkspace
---@param entries JLogEntry[] read so far; `ws.entries` when `early`
---@param read JLogReader
---@param early boolean the entries read so far are shown already
---@param counter JLogFacetCounter counts of `entries` when `early`
local function load_first(ws, entries, read, early, counter)
  local token = {}

  ws.loading, ws.load_token = true, token
  vim.defer_fn(function()
    if early then
      load_rest(ws, entries, read, function()
        ws:apply(nil, counter)
      end, counter, token)

      return
    end
    -- shown once loaded and ordered, counted by that apply
    load_rest(ws, entries, read, function(loaded)
      ws.entries = loaded
      ws:apply()
    end, nil, token)
  end, 0)
end

---Open (or focus) the workspace for a file or buffer: view on the left, sidebar on the right.
---@param target JLogOpenTarget
---@return JLogWorkspace|nil
---@return string|nil err
M.open = function(target)
  local opts = config.options
  local path = target.path and vim.fn.fnamemodify(target.path, ":p")
  local key = path or ("buf:" .. tostring(target.bufnr))
  local existing = registry[key]
  local text, format, err, ws
  local order, read, early, more
  local index, paged, range, deadline, tail
  local entries = {}
  local counter = facets.counter()
  local function count_entry(entry, decoded)
    facets.add(counter, entry_model.flatten(entry, decoded))
  end

  if existing and vim.api.nvim_tabpage_is_valid(existing.tab) then
    vim.api.nvim_set_current_tabpage(existing.tab)

    return existing
  end

  text, err = read_source(path, target.bufnr)
  if not text then
    return nil, err
  end
  format = detect.detect(text:sub(1, HEAD_LIMIT), opts) or (target.force and "jsonl" or nil)
  if not format then
    return nil, "not a recognized log format"
  end
  order = source.element_order(text, format)
  -- index until page 1 is known, so the first screen is page 1; the rest of the index follows in ticks
  index = new_index(text, format, order, opts)
  -- page 1 starts where the source does unless it is the end: then the first screen needs no more than a tick of it
  if index then
    deadline = vim.uv.hrtime() + (index.from_end and M.open_index_ns or M.timing.tick_ns)
    repeat
      index:scan(math.min(deadline, vim.uv.hrtime() + M.timing.tick_ns))
      paged = is_paged(index)
    until paged ~= nil or vim.uv.hrtime() >= deadline
  end
  range = paged and index:range(1)
  -- the first elements show early only when they are the top of the view; jsonl reverses
  early = format == "jsonl" or (order ~= "none" and (opts.view.sort == "desc") == (order == "desc"))
  -- a page from the file's end shows newest first: its first screen is the page's last lines, then the whole page
  tail = range and format == "jsonl" and index.from_end
  read = tail and tail_reader(text, range, M.load_sizes.first)
    or range and page_reader(text, format, range)
    or source_reader(text, format, order)
  -- only the first lines or elements are parsed before the first screen; the rest follows in chunks
  if not index or paged ~= nil or not index.from_end then
    more = read(entries, early and count_entry or nil, M.load_sizes.first)
  end

  ws = setmetatable({
    key = key,
    path = path,
    bufnr = target.bufnr,
    format = format,
    entries = (early or not more) and entries or {},
    stored_newest_first = order == "desc",
    opts = opts,
    generation = 0,
    rendered = 0,
    timer = vim.uv.new_timer(),
    fields_seen = {},
    published = { names = 0, at = 0 },
    state = {
      filters = {},
      group = nil,
      mode = opts.view.mode,
      reverse = (opts.view.sort == "desc") ~= (order == "desc"),
      expanded = {},
    },
  }, Workspace)
  if paged then
    ws.pages, ws.page, ws.core = index, 1, core_of(range)
  end
  ws.view = view_mod.new(ws)
  ws.sidebar = sidebar_mod.new(ws)
  create_layout(ws, path)

  registry[key] = ws
  tune_gc()
  ws.augroup = vim.api.nvim_create_augroup("jlog.workspace." .. key, { clear = true })
  -- tabpage handles are not reliably in the event data: check whether our own tab is gone
  vim.api.nvim_create_autocmd("TabClosed", {
    group = ws.augroup,
    callback = function()
      if not vim.api.nvim_tabpage_is_valid(ws.tab) then
        ws:close()
      end
    end,
  })
  -- `:q` in the view wipes its buffer (bufhidden=wipe): the sidebar alone is no workspace
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = ws.augroup,
    buffer = ws.view.bufnr,
    callback = function()
      vim.schedule(function()
        ws:close()
      end)
    end,
  })
  if path then
    snapshot(ws, text)
    watch_file(ws)
  else
    watch_buffer(ws)
  end
  -- the first slice was counted as it was parsed; the load goes on counting into the same counter
  ws:apply(nil, early and counter or nil)
  if index and not index.done then
    ws.indexing = index
    vim.defer_fn(function()
      -- once paging is known: page 1 loads, or the load goes on from the first slice (none if page 1 is the end)
      scan_pages(ws, index, paged == nil and function(has_pages)
        if has_pages then
          ws.pages = index
          load_page(ws, 1)

          return
        end
        load_first(ws, entries, read, early, counter)
      end or nil)
    end, 0)
  end
  if paged == nil and ws.indexing then
    -- page 1 is not known yet: the start of the source, or an empty view rather than the wrong end of the log
    ws.loading = true
    ws.view:set_winbar("jlog · indexing…")
  elseif tail and range.core_last_line - range.first_src + 1 > M.load_sizes.first then
    load_page(ws, 1)
  elseif not tail and more then
    load_first(ws, entries, read, early, counter)
  end

  return ws
end

return M
