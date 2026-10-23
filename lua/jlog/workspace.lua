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
---@field closed boolean|nil
---@field size integer bytes of the file read so far (path sources)
---@field complete boolean the bytes read so far end on a newline
---@field check string last bytes read, to detect a rewritten file
---@field next_lnum integer source line number of the next appended line
---@field counter JLogFacetCounter|nil facet counts of the last apply
---@field rendered integer generation of the last apply that finished rendering
---@field watcher uv.uv_fs_event_t|nil
---@field timer uv.uv_timer_t|nil debounces reloads
---@field poll uv.uv_timer_t|nil polls for the file to come back after it was deleted or rotated
---@field loading boolean|nil the rest of a jsonl file is still being parsed in chunks
---@field reload_pending boolean|nil a reload arrived while loading
local Workspace = {}
Workspace.__index = Workspace

local M = {}

local HEAD_LIMIT = 65536
local SYNC_LIMIT = 20000
-- entries scanned between checks of the tick's time budget
local SCAN_BATCH = 500
-- a chunked loop yields to the event loop after this much work, keeping every tick within ~16ms
local TICK_NS = 12e6
local DEBOUNCE_MS = 200
local TAIL_CHECK = 256
local POLL_MS = 500

-- jsonl lines parsed before the first screen, and later between checks of the tick's time budget
M.load_sizes = { first = 2000, chunk = 500 }

---@type table<string, JLogWorkspace>
local registry = {}

-- shortcut: a sync read of 100MB takes tens of ms; read async if that ever matters
---@param path string
---@return string|nil
---@return string|nil err
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

---An empty, unmodified buffer, unnamed or named after the file (auto-open's stand-in for the raw file).
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

---Wipe empty, unmodified buffers named `path` (e.g. auto-open's placeholder): `:tabedit` would reuse such a
---buffer without reading the file, and a `:w` there would truncate it.
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
  -- the empty buffer goes away once the view replaces it: a kept placeholder named after the file would
  -- later be reused by `:tabedit` without reading the file, and `:w` there would truncate it
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
end

---Filter, count facets (when the sidebar is shown), group, then render view, sidebar and winbar.
---More than 20000 entries are scanned in chunks across event-loop ticks; a newer apply supersedes this one.
---@param on_done fun()|nil called once the view has rendered
Workspace.apply = function(self, on_done)
  local generation = self.generation + 1
  local entries, opts, state = self.entries, self.opts, self.state
  local count = #entries
  local field = state.group
  local counter = window_in_tab(self, self.sidebar.bufnr) and facets.counter() or nil
  local matched = {}
  local group_values = {}
  local summary_values = {}
  local lines = vim.deepcopy(state.filters)
  local pred, errors, invalid
  local entry, decoded, decoded_done
  local next_index = 1

  self.generation = generation
  self.counter = counter
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

  -- each entry is decoded at most once per apply, and only when a filter, group or facet needs it
  local function current_decoded()
    if not decoded_done then
      decoded, decoded_done = entry_model.decode(entry), true
    end

    return decoded
  end
  local ctx = {
    raw = "",
    get = function(path)
      return entry_model.get(entry, current_decoded(), path, opts)
    end,
  }

  local function scan(first, last)
    for index = first, last do
      entry, decoded_done = entries[index], false
      ctx.raw = entry_model.key(entry)
      if pred(ctx) then
        matched[index] = true
        if counter then
          facets.add(counter, entry_model.flatten(entry, current_decoded()))
        end
      end
      if field then
        group_values[index] = entry_model.get(entry, current_decoded(), field, opts)
        -- read now, in the time-boxed scan: decoding again while building groups is one long tick
        for name, values in pairs(summary_values) do
          values[index] = entry_model.get(entry, current_decoded(), name, opts)
        end
      end
    end
    entry, decoded = nil, nil
  end

  local function finish()
    local cursor_entry = self.view:entry_at_cursor()
    local items, shown = group.build(count, {
      pred = function(index)
        return matched[index] == true
      end,
      field = field,
      reverse = state.reverse,
      get = function(index, path)
        return (path == field and group_values or summary_values[path])[index]
      end,
    })

    if counter then
      publish_facets(self, counter)
    end
    self.view:set_winbar(winbar_text(self, shown))
    self.sidebar:render()
    self.view:render(items, function()
      self.rendered = generation
      if cursor_entry then
        self.view:goto_entry(cursor_entry)
      end
      if on_done then
        on_done()
      end
    end)
  end

  local function step()
    local deadline = vim.uv.hrtime() + TICK_NS
    local last

    if self.generation ~= generation or self.closed then
      return
    end
    repeat
      last = math.min(next_index + SCAN_BATCH - 1, count)
      scan(next_index, last)
      next_index = last + 1
    until next_index > count or vim.uv.hrtime() >= deadline
    if next_index > count then
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

  if count <= SYNC_LIMIT then
    scan(1, count)
    finish()

    return
  end
  step()
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

---The complete new lines of a jsonl file that only grew, or nil when it must be rebuilt. A partial last line
---stays unread until it is completed.
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
  local entries, view, counter = ws.entries, ws.view, ws.counter
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
    if matches and counter and index > old_count then
      facets.add(counter, entry_model.flatten(entry, decoded))
    end
  end

  view:append(indexes, refresh)
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

---Pick up changes to the source: a grown jsonl file only parses its new lines; anything else is rebuilt.
Workspace.reload = function(self)
  local tail, old_count, old_key, text, entries, err

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
    if
      self.state.group
      or self.state.reverse
      or self.rendered ~= self.generation
      or not extend_view(self, old_count, old_key)
    then
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
  entries, err = source.build(text, self.format)
  if err then
    return
  end
  if self.path then
    snapshot(self, text)
  end
  replace_entries(self, entries)
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
  local saved = vim.o.eventignore
  local ok, err

  if self.path then
    wipe_placeholders(self.path)
    -- keep auto-open from claiming the file again
    vim.opt.eventignore:append("BufReadCmd")
    ok, err = pcall(vim.cmd.tabedit, vim.fn.fnameescape(self.path))
    vim.o.eventignore = saved
    if ok then
      -- auto-open leaves buffers marked raw alone, also on `:edit!`
      vim.b.jlog_raw = true
    end
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

---Parse the rest of a jsonl file in chunks across event-loop ticks, then apply once for the full entry list.
---@param ws JLogWorkspace
---@param text string
---@param pos integer byte position of the next unparsed line
---@param lnum integer source line number of that line
local function load_rest(ws, text, pos, lnum)
  local deadline = vim.uv.hrtime() + TICK_NS
  local lines

  if ws.closed then
    return
  end
  repeat
    lines, pos = take_lines(text, pos, M.load_sizes.chunk)
    source.append_lines(ws.entries, lines, lnum)
    lnum = lnum + #lines
  until pos > #text or vim.uv.hrtime() >= deadline
  if pos <= #text then
    ws.view:set_winbar("jlog · loading " .. math.floor(pos * 100 / #text) .. "%")
    vim.defer_fn(function()
      load_rest(ws, text, pos, lnum)
    end, 0)

    return
  end

  ws.loading = nil
  ws:apply()
  if ws.reload_pending then
    ws.reload_pending = nil
    ws:reload()
  end
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
    entries, err = source.build(text, format)
    if not entries and not target.force then
      return nil, err
    end
    -- a forced open of a broken array (e.g. a truncated download) still shows every line
    format = entries and format or "jsonl"
  end
  if format == "jsonl" then
    -- only the first lines are parsed before the first screen; the rest follows in chunks
    entries = {}
    lines, pos = take_lines(text, 1, M.load_sizes.first)
    source.append_lines(entries, lines, 1)
    lnum = #lines + 1
  end

  ws = setmetatable({
    key = key,
    path = path,
    bufnr = target.bufnr,
    format = format,
    entries = entries,
    opts = opts,
    generation = 0,
    rendered = 0,
    timer = vim.uv.new_timer(),
    fields_seen = {},
    state = {
      filters = {},
      group = nil,
      mode = opts.view.mode,
      reverse = opts.view.sort == "desc",
      expanded = {},
    },
  }, Workspace)
  ws.view = view_mod.new(ws)
  ws.sidebar = sidebar_mod.new(ws)
  create_layout(ws, path)

  registry[key] = ws
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
  ws:apply()
  if pos and pos <= #text then
    ws.loading = true
    vim.defer_fn(function()
      load_rest(ws, text, pos, lnum)
    end, 0)
  end

  return ws
end

return M
