local config = require("jlog.config")
local detect = require("jlog.parse.detect")
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local gc = require("jlog.core.gc")
local layout = require("jlog.workspace.layout")
local loader = require("jlog.workspace.loader")
local progress_mod = require("jlog.core.progress")
local query = require("jlog.workspace.query")
local scope = require("jlog.workspace.scope")
local sidebar_mod = require("jlog.ui.sidebar")
local store_mod = require("jlog.query.store")
local view_mod = require("jlog.ui.view")
local watcher = require("jlog.workspace.watcher")

---@class JLogOpenTarget
---@field path string|nil
---@field bufnr integer|nil
---@field force boolean|nil open even when detection fails (as jsonl)

---@class JLogWorkspaceState
---@field filters string[] valid filter clauses, one per line (AND between lines)
---@field group string|nil
---@field limit integer|nil entries shown at most, the first in display order
---@field group_limit integer|nil groups shown at most, the first in display order
---@field mode JLogViewMode
---@field reverse boolean
---@field expanded table<integer, boolean> entry index -> toggled away from `mode`
---@field ignored table<string, boolean> field paths left out of compact lines

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
---@field store JLogStore
---@field fields_seen table<string, boolean>
---@field published {names: integer, at: number} fields the sidebar shows from the current counter, and when
---@field closed boolean|nil
---@field size integer bytes of the file read so far (path sources)
---@field complete boolean the bytes read so far end on a newline
---@field check string last bytes read, to detect a rewritten file
---@field next_lnum integer source line number of the next appended line
---@field rendered integer store generation of the last apply that finished rendering
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
---@field index_notified boolean|nil the scan of `indexing` said it started, so it says when it is done
---@field appended string[]|nil lines appended since the index was built, until it is built again
---@field load_token table|nil the page or first load running; a newer one stops it
---@field target_page integer|nil the page last asked for, which `ws.page` becomes once it has loaded
---@field shown integer entries shown by the last apply, for the winbar
---@field scan JLogScan|nil the count of the filters' matches on every page, running or done
---@field scan_key string|nil the filters `scan` counts
---@field scan_index JLogPageIndex|nil the page index `scan` reads
---@field page_counts integer[]|nil matches per page, once `scan` is done
---@field scope JLogScope `all` while the view shows the matches of every page instead of one page
---@field reading fun()|nil stops reading the scan's matches into the combined view
---@field enter_pending boolean|nil the combined view was asked for while counting: it opens once counted
---@field scope_pref JLogScope what a filter shows once counted: `paging.filter_scope` until `A` or `:JLog scope` picks
local Workspace = {}
Workspace.__index = Workspace
Workspace.focus_sidebar = layout.focus_sidebar
Workspace.toggle_sidebar = layout.toggle_sidebar
Workspace.open_raw = layout.open_raw
Workspace.apply = query.apply
Workspace.add_filter = query.add_filter
Workspace.toggle_value = query.toggle_value
Workspace.clear_filters = query.clear_filters
Workspace.clear_all = query.clear_all
Workspace.set_group = query.set_group
Workspace.toggle_reverse = query.toggle_reverse
Workspace.toggle_ignore = query.toggle_ignore
Workspace.goto_page = loader.goto_page
Workspace.goto_match_page = scope.goto_match_page
Workspace.step_page = scope.step_page

---Show the matches of every page in one view (`all`), or go back to a page (`page`).
---@param name JLogScope
Workspace.set_scope = function(self, name)
  scope.choose(self, name, query.replace_entries)
end

---Switch between every page's matches and a page, and keep that choice for later filters.
Workspace.toggle_scope = function(self)
  scope.choose(self, self.scope == "all" and "page" or "all", query.replace_entries)
end
Workspace.reload = loader.reload

local M = {}

local HEAD_LIMIT = 65536

---@type table<string, JLogWorkspace>
local registry = {}

---Close the workspace tab, wipe its buffers and forget it. Also runs when its tab is closed some other way.
Workspace.close = function(self)
  if self.closed then
    return
  end
  self.closed = true
  registry[self.key] = nil
  scope.cancel(self)
  gc.drop()
  -- work stopped by the close never reports done; end its progress messages here
  progress_mod.cancel(self.key)
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
  self.view:drop_cache()
  for _, bufnr in ipairs({ self.view.bufnr, self.sidebar.bufnr }) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
  gc.release_compiled()
end

---Field paths seen in facets so far, for completion.
---@return string[]
Workspace.field_names = function(self)
  local names = vim.tbl_keys(self.fields_seen)

  table.sort(names)

  return names
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
  local text, format, err, ws, slice
  local counter = facets.counter()
  local function count_entry(entry, decoded)
    facets.add(counter, entry_model.flatten(entry, decoded))
  end

  if existing and vim.api.nvim_tabpage_is_valid(existing.tab) then
    vim.api.nvim_set_current_tabpage(existing.tab)

    return existing
  end

  text, err = loader.read_source(path, target.bufnr)
  if not text then
    return nil, err
  end
  format = detect.detect(text:sub(1, HEAD_LIMIT), opts) or (target.force and "jsonl" or nil)
  if not format then
    return nil, "not a recognized log format"
  end
  slice = loader.prepare(text, format, opts, count_entry)

  ws = setmetatable({
    key = key,
    path = path,
    bufnr = target.bufnr,
    format = format,
    entries = (slice.early or not slice.more) and slice.entries or {},
    stored_newest_first = slice.order == "desc",
    scope = "page",
    scope_pref = opts.paging and opts.paging.filter_scope or "page",
    opts = opts,
    rendered = 0,
    timer = vim.uv.new_timer(),
    fields_seen = {},
    published = { names = 0, at = 0 },
    state = {
      filters = {},
      group = nil,
      mode = opts.view.mode,
      reverse = (opts.view.sort == "desc") ~= (slice.order == "desc"),
      expanded = {},
      ignored = {},
    },
  }, Workspace)
  for _, name in ipairs(opts.view.ignore_fields) do
    ws.state.ignored[name] = true
  end
  if slice.paged then
    ws.pages, ws.page, ws.core = slice.index, 1, loader.core_of(slice.range)
  end
  ws.store = store_mod.new(ws)
  ws.view = view_mod.new(ws)
  ws.sidebar = sidebar_mod.new(ws)
  layout.create(ws, path)

  registry[key] = ws
  gc.hold()
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
  ws.view.on_close = function()
    vim.schedule(function()
      ws:close()
    end)
  end
  if path then
    watcher.snapshot(ws, text)
    watcher.file(ws)
  else
    watcher.buffer(ws)
  end
  -- started first so the first apply sees a load still running: its counts are partial (its work is deferred anyway)
  loader.start(ws, slice, counter)
  -- the first slice was counted as it was parsed; the load goes on counting into the same counter
  ws:apply(nil, slice.early and counter or nil)

  return ws
end

return M
