local config = require("jlog.config")
local detect = require("jlog.parse.detect")
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local filter = require("jlog.query.filter")
local group = require("jlog.query.group")
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
  view:set_winbar(winbar_text(ws, #view.items))
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
---@return string[] lines
---@return integer next_pos
local function take_lines(text, pos, count)
  local lines = {}
  local newline

  for _ = 1, count do
    if pos > #text then
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

---Reads the next chunk into `entries`; returns the fraction of the text read, or nil when done.
---@alias JLogReader fun(entries: JLogEntry[], on_json: function|nil): number|nil

---@param text string
---@param pos integer byte position of the next unparsed line
---@param lnum integer source line number of that line
---@return JLogReader
local function line_reader(text, pos, lnum)
  return function(entries, on_json)
    local lines

    lines, pos = take_lines(text, pos, M.load_sizes.chunk)
    source.append_lines(entries, lines, lnum, on_json)
    lnum = lnum + #lines

    return pos <= #text and pos / #text or nil
  end
end

---A broken array keeps what was read; the unparsed rest follows as plain entries, one per line.
---@param entries JLogEntry[] mutated
---@param text string
---@param rest_at integer where the unparsed rest starts
---@param err string
local function keep_broken_rest(entries, text, rest_at, err)
  vim.notify("jlog: broken JSON array: " .. err .. "; the rest is shown as plain lines", vim.log.levels.WARN)
  source.append_plain(entries, text:sub(rest_at))
end

---@param text string
---@param pos integer|nil where `source.read_elements` goes on; nil when nothing is left
---@param format JLogFormat
---@return JLogReader
local function element_reader(text, pos, format)
  return function(entries, on_json)
    local chunk, next_pos, err

    if not pos or (#entries == 0 and not text:find("%S")) then
      return nil
    end
    chunk, next_pos, err = source.read_elements(text, pos, M.load_sizes.chunk, format, #entries + 1, on_json)
    vim.list_extend(entries, chunk)
    if err then
      keep_broken_rest(entries, text, next_pos, err)

      return nil
    end
    pos = next_pos

    return pos and pos / #text or nil
  end
end

---Parse the rest of the source into `entries` in chunks across event-loop ticks, then call `on_done` once.
---@param ws JLogWorkspace
---@param entries JLogEntry[] mutated
---@param read JLogReader
---@param on_done fun(entries: JLogEntry[])
---@param counter JLogFacetCounter|nil counts the facets of the loaded JSON entries, from the load's own decode
local function load_rest(ws, entries, read, on_done, counter)
  local deadline = vim.uv.hrtime() + M.timing.tick_ns
  local fraction, progress
  local count_entry = counter
    and function(entry, decoded)
      facets.add(counter, entry_model.flatten(entry, decoded))
    end

  if ws.closed then
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
      load_rest(ws, entries, read, on_done, counter)
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

  return function(entries, on_json)
    local fraction

    if not sorter then
      fraction = read(entries, on_json)
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
---@param pos integer|nil
---@param format JLogFormat
---@param order "asc"|"desc"|"none"
---@return JLogReader
local function array_reader(text, pos, format, order)
  local read = element_reader(text, pos, format)

  return (format == "loki" and order == "none") and sorting_reader(read) or read
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

---Pick up changes to the source: a grown jsonl file only parses its new lines; anything else is rebuilt.
Workspace.reload = function(self)
  local tail, old_count, old_key, text, err, order, read

  if self.closed then
    return
  end
  if self.loading then
    self.reload_pending = true

    return
  end
  tail = self.path and self.format == "jsonl" and read_appended(self) or nil
  if tail then
    old_count = #self.entries
    old_key = old_count > 0 and entry_model.key(self.entries[old_count]) or nil
    source.append_lines(self.entries, vim.split(tail:sub(1, -2), "\n", { plain = true }), self.next_lnum)
    self.size = self.size + #tail
    self.check = (self.check .. tail):sub(-TAIL_CHECK)
    self.next_lnum = self.next_lnum + select(2, tail:gsub("\n", ""))
    if tail == "" then
      return
    end
    if self.state.group or self.rendered ~= self.generation or not extend_view(self, old_count, old_key) then
      self:apply()
    end

    return
  end

  text, err = read_source(self.path, self.bufnr)
  if err then
    -- a missing file is reported by the watcher, which waits for it to come back
    if not self.path or vim.uv.fs_stat(self.path) then
      vim.notify("jlog: cannot reload: " .. tostring(err), vim.log.levels.WARN)
    end

    return
  end
  if self.path then
    snapshot(self, text)
  end
  -- parsed in chunks like at open; the old entries stay shown until the new ones are complete
  order = source.element_order(text, self.format)
  read = self.format == "jsonl" and line_reader(text, 1, 1) or array_reader(text, 1, self.format, order)
  self.loading = true
  vim.defer_fn(function()
    load_rest(self, {}, read, function(loaded)
      set_stored_order(self, order)
      replace_entries(self, loaded)
    end)
  end, 0)
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

---Open (or focus) the workspace for a file or buffer: view on the left, sidebar on the right.
---@param target JLogOpenTarget
---@return JLogWorkspace|nil
---@return string|nil err
M.open = function(target)
  local opts = config.options
  local path = target.path and vim.fn.fnamemodify(target.path, ":p")
  local key = path or ("buf:" .. tostring(target.bufnr))
  local existing = registry[key]
  local text, format, entries, err, ws
  local pos, lnum, lines
  local order, read, early
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
  if format ~= "jsonl" then
    order = source.element_order(text, format)
    -- the first elements show early only when they are the top of the view
    early = order ~= "none" and (opts.view.sort == "desc") == (order == "desc")
    entries, pos, err = source.read_elements(text, 1, M.load_sizes.first, format, 1, early and count_entry or nil)
    if err then
      keep_broken_rest(entries, text, pos, err)
      pos = nil
    end
    read = array_reader(text, pos, format, order)
  end
  if format == "jsonl" then
    -- only the first lines are parsed before the first screen; the rest follows in chunks
    entries = {}
    lines, pos = take_lines(text, 1, M.load_sizes.first)
    source.append_lines(entries, lines, 1, count_entry)
    lnum = #lines + 1
    read = line_reader(text, pos, lnum)
    early = true
  end

  ws = setmetatable({
    key = key,
    path = path,
    bufnr = target.bufnr,
    format = format,
    entries = early and entries or {},
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
  if early and pos and pos <= #text then
    ws.loading = true
    vim.defer_fn(function()
      load_rest(ws, ws.entries, read, function()
        ws:apply(nil, counter)
      end, counter)
    end, 0)
  elseif not early then
    -- shown once loaded and ordered, counted by that apply
    ws.loading = true
    vim.defer_fn(function()
      load_rest(ws, entries, read, function(loaded)
        ws.entries = loaded
        ws:apply()
      end)
    end, 0)
  end

  return ws
end

return M
