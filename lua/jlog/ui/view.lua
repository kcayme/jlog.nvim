local entry_model = require("jlog.parse.entry")
local keymaps = require("jlog.ui.keymaps")
local render = require("jlog.ui.render")

---@class JLogView
---@field bufnr integer
---@field ws table workspace (`entries`, `opts`, `state`, `format`)
---@field items JLogItem[]
---@field line_item integer[] buffer line -> item index
---@field item_line integer[] item index -> first buffer line
---@field entry_item table<integer, integer> entry index -> item index
---@field first_header integer|nil item index of the first group header
---@field generation integer bumped per render; stale chunked renders stop
---@field winbar_text string
---@field redraw_spans table<integer, JLogSpan[][]> item index -> spans, valid for one redraw only
local View = {}
View.__index = View

local M = {}

local SYNC_LIMIT = 5000
local CHUNK_SIZE = 2000
local ERROR_LEVELS = { error = true, fatal = true, panic = true }

local ns = vim.api.nvim_create_namespace("jlog.view")

---@type table<integer, JLogView>
local views = {}

---@param view JLogView
---@param item JLogItem
---@return boolean
local function is_expanded(view, item)
  local state = view.ws.state

  return (state.mode == "expanded") ~= (state.expanded[item.idx] == true)
end

---@param view JLogView
---@param item JLogItem
---@param lines_only boolean
---@return string[] lines
---@return JLogSpan[][]|nil spans
local function item_lines(view, item, lines_only)
  local line, span

  if item.kind == "header" then
    line, span = render.header(item.group)

    return { line }, { span }
  end
  if is_expanded(view, item) then
    return render.expanded(view.ws.entries[item.idx], view.ws.opts)
  end

  return render.compact(view.ws.entries[item.idx], view.ws.opts, lines_only)
end

---@param view JLogView
---@param start_line integer 0-based
---@param end_line integer 0-based exclusive, -1 for the end
---@param lines string[]
local function write_lines(view, start_line, end_line, lines)
  vim.bo[view.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(view.bufnr, start_line, end_line, false, lines)
  vim.bo[view.bufnr].modifiable = false
end

---@param view JLogView
---@param text string
local function apply_winbar(view, text)
  local winbar = text == "" and "" or "%#JLogWinbar#" .. text:gsub("%%", "%%%%")

  for _, winid in ipairs(vim.fn.win_findbuf(view.bufnr)) do
    vim.wo[winid].winbar = winbar
  end
end

---@param view JLogView
---@param winid integer
local function apply_window_options(view, winid)
  local wo = vim.wo[winid][0]

  wo.wrap = false
  wo.foldexpr = "v:lua.require'jlog.ui.view'.foldexpr(v:lnum)"
  wo.foldlevel = 99
  -- evaluating a foldexpr per line costs seconds on 500k lines: only pay it when there are groups
  wo.foldmethod = view.first_header and "expr" or "manual"
end

---Build lines for items `first..last` and append them after line `at` (0-based).
---@param view JLogView
---@param first integer
---@param last integer
---@param replace boolean replace the whole buffer instead of appending
local function append_items(view, first, last, replace)
  local items, line_item, item_line, entry_item = view.items, view.line_item, view.item_line, view.entry_item
  local buffer_lines = {}
  local line_count = #line_item
  local lines

  for item_index = first, last do
    lines = item_lines(view, items[item_index], true)
    item_line[item_index] = line_count + 1
    if items[item_index].kind == "entry" then
      entry_item[items[item_index].idx] = item_index
    elseif not view.first_header then
      view.first_header = item_index
    end
    for _, line in ipairs(lines) do
      line_count = line_count + 1
      line_item[line_count] = item_index
      buffer_lines[#buffer_lines + 1] = line
    end
  end
  write_lines(view, replace and 0 or #line_item - #buffer_lines, -1, buffer_lines)
end

---@param view JLogView
---@return integer|nil
local function window_of(view)
  if vim.api.nvim_get_current_buf() == view.bufnr then
    return vim.api.nvim_get_current_win()
  end
  local winid = vim.fn.bufwinid(view.bufnr)

  return winid ~= -1 and winid or nil
end

---@param view JLogView
---@return integer|nil item index under the cursor
local function item_at_cursor(view)
  local winid = window_of(view)

  if not winid then
    return nil
  end

  return view.line_item[vim.api.nvim_win_get_cursor(winid)[1]]
end

---@param view JLogView
---@param item JLogItem
---@return boolean
local function is_error(view, item)
  local entry, level

  if item.kind ~= "entry" then
    return false
  end
  entry = view.ws.entries[item.idx]
  level = entry_model.get(entry, entry_model.decode(entry), "level", view.ws.opts)

  return level ~= nil and ERROR_LEVELS[tostring(level):lower()] == true
end

---@param _ any
---@param _winid integer
---@param bufnr integer
---@return boolean
local function on_win(_, _winid, bufnr)
  local view = views[bufnr]

  if not view then
    return false
  end
  view.redraw_spans = {}

  return true
end

---@param _ any
---@param _winid integer
---@param bufnr integer
---@param row integer 0-based
local function on_line(_, _winid, bufnr, row)
  local view = views[bufnr]
  local item_index = view and view.line_item[row + 1]
  local spans, _

  if not item_index then
    return
  end
  spans = view.redraw_spans[item_index]
  if not spans then
    _, spans = item_lines(view, view.items[item_index], false)
    view.redraw_spans[item_index] = spans
  end
  for _, span in ipairs(spans[row + 2 - view.item_line[item_index]] or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, span[1], {
      end_col = span[2],
      hl_group = span[3],
      ephemeral = true,
    })
  end
end

vim.api.nvim_set_decoration_provider(ns, { on_win = on_win, on_line = on_line })

---Render `items`, replacing the buffer. More than 5000 items render in chunks across event-loop ticks.
---@param items JLogItem[]
---@param on_done fun()|nil
View.render = function(self, items, on_done)
  local generation = self.generation + 1
  local total = #items
  local next_item

  self.generation = generation
  self.items, self.line_item, self.item_line, self.entry_item, self.first_header = items, {}, {}, {}, nil

  local function finish()
    for _, winid in ipairs(vim.fn.win_findbuf(self.bufnr)) do
      apply_window_options(self, winid)
    end
    if on_done then
      on_done()
    end
  end

  if total == 0 then
    write_lines(self, 0, -1, {})
    finish()

    return
  end
  if total <= SYNC_LIMIT then
    append_items(self, 1, total, true)
    finish()

    return
  end

  -- the first chunk is synchronous so the first screen shows at once
  append_items(self, 1, CHUNK_SIZE, true)
  next_item = CHUNK_SIZE + 1

  local function step()
    local last = math.min(next_item + CHUNK_SIZE - 1, total)

    if self.generation ~= generation or not vim.api.nvim_buf_is_valid(self.bufnr) then
      return
    end
    append_items(self, next_item, last, false)
    next_item = last + 1
    if next_item > total then
      apply_winbar(self, self.winbar_text)
      finish()

      return
    end
    apply_winbar(self, "jlog · rendering " .. math.floor(last * 100 / total) .. "%")
    vim.schedule(step)
  end

  apply_winbar(self, "jlog · rendering " .. math.floor(CHUNK_SIZE * 100 / total) .. "%")
  vim.schedule(step)
end

---@return integer|nil entry index under the cursor
View.entry_at_cursor = function(self)
  local item_index = item_at_cursor(self)
  local item = item_index and self.items[item_index]

  if not item or item.kind ~= "entry" then
    return nil
  end

  return item.idx
end

---@param idx integer entry index
View.goto_entry = function(self, idx)
  local item_index = self.entry_item[idx]
  local winid = window_of(self)

  if not item_index or not winid then
    return
  end
  vim.api.nvim_win_set_cursor(winid, { self.item_line[item_index], 0 })
end

---Expand or collapse the entry under the cursor in place.
View.toggle_entry = function(self)
  local item_index = item_at_cursor(self)
  local item = item_index and self.items[item_index]
  local line_item, item_line = self.line_item, self.item_line
  local old_count = #line_item
  local first_line, old_end, lines, delta, expanded

  if not item or item.kind ~= "entry" then
    return
  end

  expanded = self.ws.state.expanded
  expanded[item.idx] = not expanded[item.idx] or nil
  first_line = item_line[item_index]
  old_end = (item_line[item_index + 1] or old_count + 1) - 1
  lines = item_lines(self, item, true)
  delta = #lines - (old_end - first_line + 1)
  write_lines(self, first_line - 1, old_end, lines)

  -- shift the line map tail by `delta`, then fill the item's new lines
  if delta > 0 then
    for line = old_count, old_end + 1, -1 do
      line_item[line + delta] = line_item[line]
    end
  elseif delta < 0 then
    for line = old_end + 1, old_count do
      line_item[line + delta] = line_item[line]
    end
    for line = old_count + delta + 1, old_count do
      line_item[line] = nil
    end
  end
  for line = first_line, first_line + #lines - 1 do
    line_item[line] = item_index
  end
  for index = item_index + 1, #item_line do
    item_line[index] = item_line[index] + delta
  end

  self:goto_entry(item.idx)
end

---Switch the whole view between compact and expanded, keeping the cursor on its entry.
View.toggle_mode = function(self)
  local idx = self:entry_at_cursor()
  local state = self.ws.state

  state.mode = state.mode == "expanded" and "compact" or "expanded"
  state.expanded = {}
  self:render(self.items, function()
    if idx then
      self:goto_entry(idx)
    end
  end)
end

---Move the cursor to the next/previous entry, or the next/previous error-level entry.
---@param kind "entry"|"error"
---@param dir 1|-1
View.move = function(self, kind, dir)
  local item_index = item_at_cursor(self)
  local item

  if not item_index then
    return
  end
  item_index = item_index + dir
  while self.items[item_index] do
    item = self.items[item_index]
    if item.kind == "entry" and (kind == "entry" or is_error(self, item)) then
      self:goto_entry(item.idx)

      return
    end
    item_index = item_index + dir
  end
end

---Show the raw source text of the entry under the cursor in a centered float.
View.show_raw = function(self)
  local idx = self:entry_at_cursor()
  local entry = idx and self.ws.entries[idx]
  local lines, width, height, bufnr

  if not entry then
    return
  end

  lines = vim.split(entry.raw, "\n", { plain = true })
  vim.list_extend(lines, entry.cont or {})
  width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width, vim.o.columns - 4)
  height = math.min(#lines, vim.o.lines - 4)

  bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].modifiable = false
  vim.b[bufnr].jlog_src = entry.src
  keymaps.attach(bufnr, "raw", self.ws)
  vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " raw ",
  })
end

---@param text string
View.set_winbar = function(self, text)
  self.winbar_text = text
  apply_winbar(self, text)
end

---@param ws table workspace: `entries`, `opts`, `state = { mode, expanded }`, `format`
---@return JLogView
M.new = function(ws)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local name = "jlog://" .. (ws.path and vim.fn.fnamemodify(ws.path, ":t") or ws.key or "log")
  local view = setmetatable({
    bufnr = bufnr,
    ws = ws,
    items = {},
    line_item = {},
    item_line = {},
    entry_item = {},
    generation = 0,
    winbar_text = "",
    redraw_spans = {},
  }, View)

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  if not pcall(vim.api.nvim_buf_set_name, bufnr, name) then
    vim.api.nvim_buf_set_name(bufnr, name .. " (" .. bufnr .. ")")
  end

  views[bufnr] = view
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = bufnr,
    callback = function()
      apply_window_options(view, vim.api.nvim_get_current_win())
      apply_winbar(view, view.winbar_text)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      views[bufnr] = nil
    end,
  })
  keymaps.attach(bufnr, "view", ws)

  return view
end

---Fold level for `lnum` of the current buffer: group headers open a fold, their entries are inside it.
---@param lnum integer
---@return string
M.foldexpr = function(lnum)
  local view = views[vim.api.nvim_get_current_buf()]
  local item_index = view and view.line_item[lnum]

  if not item_index or not view.first_header then
    return "0"
  end
  if view.items[item_index].kind == "header" then
    return ">1"
  end

  return item_index > view.first_header and "1" or "0"
end

return M
