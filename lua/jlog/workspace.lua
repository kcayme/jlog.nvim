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
local Workspace = {}
Workspace.__index = Workspace

local M = {}

local HEAD_LIMIT = 65536
local SYNC_LIMIT = 20000
local CHUNK_SIZE = 5000

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
  local lines = vim.deepcopy(state.filters)
  local pred, errors, invalid
  local entry, decoded, decoded_done
  local next_index = 1

  self.generation = generation
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
        if path == field then
          return group_values[index]
        end

        -- shortcut: group summary fields (status/method/path) decode again; cache them if grouping gets slow
        return entry_model.get(entries[index], entry_model.decode(entries[index]), path, opts)
      end,
    })

    if counter then
      self.sidebar.facets = facets.result(counter, opts.facets.top_values)
      for _, facet in ipairs(self.sidebar.facets) do
        self.fields_seen[facet.name] = true
      end
    end
    self.view:set_winbar(winbar_text(self, shown))
    self.sidebar:render()
    self.view:render(items, function()
      if cursor_entry then
        self.view:goto_entry(cursor_entry)
      end
      if on_done then
        on_done()
      end
    end)
  end

  local function step()
    local last = math.min(next_index + CHUNK_SIZE - 1, count)

    if self.generation ~= generation or self.closed then
      return
    end
    scan(next_index, last)
    next_index = last + 1
    if next_index > count then
      finish()

      return
    end
    self.view:set_winbar("jlog · applying " .. math.floor(last * 100 / count) .. "%")
    vim.schedule(step)
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

---Close the workspace tab, wipe its buffers and forget it. Also runs when its tab is closed some other way.
Workspace.close = function(self)
  if self.closed then
    return
  end
  self.closed = true
  registry[self.key] = nil
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)

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
  entries, err = source.build(text, format)
  if not entries then
    return nil, err
  end

  ws = setmetatable({
    key = key,
    path = path,
    bufnr = target.bufnr,
    format = format,
    entries = entries,
    opts = opts,
    generation = 0,
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
  ws:apply()

  return ws
end

return M
