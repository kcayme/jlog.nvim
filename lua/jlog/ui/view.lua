local entry_model = require("jlog.parse.entry")
local cache = require("jlog.ui.cache")
local keymaps = require("jlog.ui.keymaps")
local render = require("jlog.ui.render")
local utils = require("jlog.utils")

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
---@field rendered_entries JLogEntry[]|nil the entries list the buffer's lines were rendered from
---@field stream JLogReuseStream|nil while a render reuses the old lines it replaces
---@field complete boolean the last render into the buffer finished
---@field edited boolean entries were expanded or collapsed in place since the last render
---@field mode JLogViewMode|nil the mode the buffer was rendered in
---@field folded table<integer, boolean> windows whose folds were made for the buffer's last render
---@field cache JLogViewBuffer|nil the other mode's finished buffer, hidden, kept until anything changes
---@field on_close fun()|nil called when the shown buffer is wiped

---Old lines below a render's new ones, read and deleted from the front; on the view so no closure keeps them alive.
---@class JLogReuseStream
---@field line_item integer[] its buffer line -> item index
---@field item_line integer[] its item index -> first line
---@field entry_item table<integer, integer> its entry index -> item index
---@field total integer its line count
---@field read_to integer old lines read (and deleted) so far
---@field used_to integer last old line handed out: entries above it can no longer be reused
---@field window string[] old lines read but not yet handed out
---@field window_first integer old line number of `window[1]`
local View = {}
View.__index = View

local M = {}

-- above this many lines, group folds are made once by hand: a foldexpr re-runs per line, seconds at 100k+ lines
M.fold_expr_limit = 50000
-- a chunked render yields to the event loop after this much work, keeping every tick within ~16ms
M.tick_ns = 12e6
-- old lines deleted per call during a render (~4ms per 50k; replacing 500k lines at once costs ~50ms)
M.trim_slice = 50000
-- old lines read back at a time while a render reuses them (~2ms per 5k)
M.read_slice = 5000

-- items built between checks of the tick's time budget (expanded entries are slower, but 64 stay well within it)
local BATCH = 64
local ERROR_LEVELS = { error = true, fatal = true, panic = true }

local ns = vim.api.nvim_create_namespace("jlog.view")
local ns_anchor = vim.api.nvim_create_namespace("jlog.view.anchor")
local ns_header = vim.api.nvim_create_namespace("jlog.view.header")

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
  -- a group header takes no line: it is a virtual line above the group's first entry
  if item.kind == "header" then
    return {}, {}
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
    vim.wo[winid][0].winbar = winbar
  end
end

---Draw the header before `item_index` as a virtual line above its first line; the mark goes when that line does.
---@param view JLogView
---@param item_index integer an entry right after a group header
local function place_header(view, item_index)
  local line = render.header(view.items[item_index - 1].group)

  vim.api.nvim_buf_set_extmark(view.bufnr, ns_header, view.item_line[item_index] - 1, 0, {
    virt_lines = { { { line, "JLogGroupHeader" } } },
    virt_lines_above = true,
    invalidate = true,
    undo_restore = false,
  })
end

---@param view JLogView
---@param item_index integer
---@return boolean
local function starts_group(view, item_index)
  local previous = view.items[item_index - 1]

  return previous ~= nil and previous.kind == "header"
end

---A virtual line above line 1 shows only when the window is scrolled up into it.
---@param view JLogView
---@param winid integer
local function show_first_header(view, winid)
  if view.first_header ~= 1 then
    return
  end
  vim.api.nvim_win_call(winid, function()
    if vim.fn.line("w0") == 1 then
      vim.fn.winrestview({ topfill = 1 })
    end
  end)
end

---One open manual fold per group, from its first entry line to the line before the next group's.
---@param view JLogView
local function create_manual_folds(view)
  local items, item_line = view.items, view.item_line
  local start

  for item_index = view.first_header, #items do
    if items[item_index].kind == "header" then
      if start then
        vim.cmd(start .. "," .. (item_line[item_index] - 1) .. "fold")
      end
      start = item_line[item_index]
    end
  end
  vim.cmd(start .. "," .. #view.line_item .. "fold")
  vim.cmd("silent! %foldopen!")
end

---@param view JLogView
---@param winid integer
local function apply_window_options(view, winid)
  local wo = vim.wo[winid][0]
  local manual = view.first_header ~= nil and #view.line_item > M.fold_expr_limit

  wo.wrap = false
  wo.foldexpr = "v:lua.require'jlog.ui.view'.foldexpr(v:lnum)"
  -- a closed fold hides the header's virtual line, so the fold line shows the header instead
  wo.foldtext = "v:lua.require'jlog.ui.view'.foldtext()"
  wo.foldlevel = 99
  -- a group of one single-line entry is a one-line fold, which only closes with this at 0
  wo.foldminlines = 0
  -- evaluating a foldexpr per line costs seconds on 500k lines: only pay it for groups in smaller views
  wo.foldmethod = (view.first_header and not manual) and "expr" or "manual"
  vim.api.nvim_win_call(winid, function()
    -- switching to manual keeps the folds of the previous render
    if wo.foldmethod == "manual" then
      vim.cmd("normal! zE")
    end
    if manual then
      create_manual_folds(view)
    end
  end)
  show_first_header(view, winid)
  view.folded[winid] = true
end

---Old lines of `item` at buffer row `row` onward, or nil if it is expanded now, new, or already passed (reordered).
---@param view JLogView
---@param item JLogItem
---@param row integer 0-based buffer row where the old lines start
---@return string[]|nil
local function take_old(view, item, row)
  local stream = view.stream
  local old_item, first, last, gap, count, kept, lines

  if item.kind ~= "entry" or is_expanded(view, item) then
    return nil
  end
  old_item = stream.entry_item[item.idx]
  first = old_item and stream.item_line[old_item]
  if not first or first <= stream.used_to then
    return nil
  end
  -- old lines up to this entry are never needed again: drop them unread, unless too many for one call
  gap = first - 1 - stream.read_to
  if gap > M.trim_slice then
    return nil
  end
  if gap > 0 then
    write_lines(view, row, row + gap, {})
    stream.read_to, stream.window, stream.window_first = first - 1, {}, first
  end
  last = first
  while stream.line_item[last + 1] == old_item do
    last = last + 1
  end
  -- the window holds old lines window_first..read_to; keep only this entry's onward before reading more
  if stream.read_to < first then
    stream.window, stream.window_first = {}, stream.read_to + 1
  elseif stream.read_to < last and first > stream.window_first then
    kept = {}
    for line = first, stream.read_to do
      kept[#kept + 1] = stream.window[line - stream.window_first + 1]
    end
    stream.window, stream.window_first = kept, first
  end
  while stream.read_to < last do
    count = math.min(M.read_slice, stream.total - stream.read_to)
    for _, text in ipairs(vim.api.nvim_buf_get_lines(view.bufnr, row, row + count, false)) do
      stream.window[#stream.window + 1] = text
    end
    write_lines(view, row, row + count, {})
    stream.read_to = stream.read_to + count
  end
  lines = {}
  for line = first, last do
    lines[#lines + 1] = stream.window[line - stream.window_first + 1]
  end
  stream.used_to = last

  return lines
end

---Build lines for items `first..last` and append them to the buffer, stopping early once `deadline` passes.
---@param view JLogView
---@param first integer
---@param last integer
---@param replace boolean replace the whole buffer instead of appending
---@param deadline number|nil `vim.uv.hrtime()` to stop at
---@param keep_tail boolean|nil insert above the old lines below the new ones (a render trims them later)
---@return integer last item index appended
local function append_items(view, first, last, replace, deadline, keep_tail)
  local items, line_item, item_line, entry_item = view.items, view.line_item, view.item_line, view.entry_item
  local buffer_lines = {}
  local line_count = #line_item
  local done = last
  local start = replace and 0 or #line_item
  local group_starts = {}
  local lines

  for item_index = first, last do
    -- a reusing render checks every item: dropping old lines can take a few ms
    if deadline and (view.stream or (item_index - first) % BATCH == BATCH - 1) and vim.uv.hrtime() >= deadline then
      done = item_index
    end
    -- the old lines start at `start` until this batch is inserted there
    lines = view.stream and take_old(view, items[item_index], start) or item_lines(view, items[item_index], true)
    item_line[item_index] = line_count + 1
    if items[item_index].kind == "entry" then
      entry_item[items[item_index].idx] = item_index
      if starts_group(view, item_index) then
        group_starts[#group_starts + 1] = item_index
      end
    elseif not view.first_header then
      view.first_header = item_index
    end
    for _, line in ipairs(lines) do
      line_count = line_count + 1
      line_item[line_count] = item_index
      buffer_lines[#buffer_lines + 1] = line
    end
    if done < last then
      break
    end
  end
  write_lines(view, start, keep_tail and start or -1, buffer_lines)
  for _, item_index in ipairs(group_starts) do
    place_header(view, item_index)
  end

  return done
end

---Delete the old lines left below the rendered ones, a slice at a time until `deadline`.
---@param view JLogView
---@param deadline number `vim.uv.hrtime()` to stop at
---@return boolean done
local function trim_stale(view, deadline)
  local keep = #view.line_item
  local count = vim.api.nvim_buf_line_count(view.bufnr)

  -- read from the buffer each time, never stored: View.append may have changed it meanwhile
  while count > keep do
    -- an empty buffer still holds one blank line
    if keep == 0 and count == 1 and vim.api.nvim_buf_get_lines(view.bufnr, 0, 1, false)[1] == "" then
      return true
    end
    -- one slice per call at least, so every tick makes progress
    write_lines(view, keep, math.min(count, keep + M.trim_slice), {})
    count = vim.api.nvim_buf_line_count(view.bufnr)
    if count > keep and vim.uv.hrtime() >= deadline then
      return false
    end
  end

  return true
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
  local core = view and view.ws.core
  local item, src, spans, _

  -- entries swapped in for an apply that has not rendered yet do not match the lines shown
  if not item_index or view.rendered_entries ~= view.ws.entries then
    return
  end
  item = view.items[item_index]
  src = core and item.kind == "entry" and view.ws.entries[item.idx].src
  -- entries outside the page's own range are overlap with its neighbours: dimmed whole
  if src and (src < core[1] or src > core[2]) then
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      end_row = row + 1,
      end_col = 0,
      hl_group = "JLogOverlap",
      ephemeral = true,
    })

    return
  end
  spans = view.redraw_spans[item_index]
  if not spans then
    _, spans = item_lines(view, item, false)
    view.redraw_spans[item_index] = spans
  end
  for _, span in ipairs(spans[row + 2 - view.item_line[item_index]] or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, span[1], {
      end_col = span[2],
      hl_group = span[3],
      ephemeral = true,
    })
    for _, cap in ipairs(M.cap_marks(span, view.ws.opts.compact.pill)) do
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, cap.col, cap.opts)
    end
  end
end

---The inline virtual text marks (left, right) that draw a pill span's caps; none without a cap group or glyph.
---@param span JLogSpan
---@param pill JLogPillOptions
---@return { col: integer, opts: table }[]
M.cap_marks = function(span, pill)
  local marks = {}
  local group = span[4]

  if not group then
    return marks
  end
  if pill.left ~= "" then
    marks[#marks + 1] = {
      col = span[1],
      opts = { virt_text = { { pill.left, group } }, virt_text_pos = "inline", ephemeral = true },
    }
  end
  if pill.right ~= "" then
    marks[#marks + 1] = {
      col = span[2],
      opts = { virt_text = { { pill.right, group } }, virt_text_pos = "inline", ephemeral = true },
    }
  end

  return marks
end

vim.api.nvim_set_decoration_provider(ns, { on_win = on_win, on_line = on_line })

---A new, empty buffer for `view`, with the view's options, autocmds and keymaps.
---@param view JLogView
---@return integer bufnr
local function create_buffer(view)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local ws = view.ws
  local name = "jlog://" .. (ws.path and vim.fn.fnamemodify(ws.path, ":t") or ws.key or "log")

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].filetype = "jlog"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  -- renders replace the whole buffer: undo would copy every old line each time (~70ms at 500k lines)
  vim.bo[bufnr].undolevels = -1
  if not pcall(vim.api.nvim_buf_set_name, bufnr, name) then
    vim.api.nvim_buf_set_name(bufnr, name .. " (" .. bufnr .. ")")
  end

  -- ephemeral inline text only lays out in a buffer that already holds a persistent inline mark
  vim.api.nvim_buf_set_extmark(bufnr, ns_anchor, 0, 0, { virt_text = { { "" } }, virt_text_pos = "inline" })

  views[bufnr] = view
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = bufnr,
    callback = function()
      local winid = vim.api.nvim_get_current_win()

      -- a window shows the folds it made for this buffer again (rebuilding them costs ~50ms at 100k+ lines)
      if not view.folded[winid] then
        apply_window_options(view, winid)
      end
      apply_winbar(view, view.winbar_text)
      -- entering the buffer resets the window's topfill after this autocmd
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
          show_first_header(view, winid)
        end
      end)
    end,
  })
  -- reaching line 1 (`gg`, `k`) scrolls to the line, not to the header above it
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = bufnr,
    callback = function()
      if vim.fn.line(".") == 1 then
        show_first_header(view, vim.api.nvim_get_current_win())
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      views[bufnr] = nil
      -- a dropped cache going away is not the view closing
      if bufnr == view.bufnr and view.on_close then
        view.on_close()
      end
    end,
  })
  keymaps.attach(bufnr, "view", ws)

  return bufnr
end

---Render `items`, replacing the buffer. What does not fit in the first ~12ms tick renders in later ticks.
---@param items JLogItem[]
---@param on_done fun()|nil
View.render = function(self, items, on_done)
  local generation = self.generation + 1
  local total = #items
  local next_item

  self.generation = generation
  -- any other render changes what is shown, so the other mode's buffer no longer matches it
  cache.drop(self)
  self.complete, self.edited, self.mode, self.folded = false, false, self.ws.state.mode, {}
  -- reuse the old lines' text when they come from the same entries (a reload that rebuilds them makes a new list)
  self.stream = self.rendered_entries == self.ws.entries
      and #self.line_item > 0
      and {
        line_item = self.line_item,
        item_line = self.item_line,
        entry_item = self.entry_item,
        total = #self.line_item,
        read_to = 0,
        used_to = 0,
        window = {},
        window_first = 1,
      }
    or nil
  self.rendered_entries = self.ws.entries
  self.items, self.line_item, self.item_line, self.entry_item, self.first_header = items, {}, {}, {}, nil

  local function finish()
    self.stream = nil
    self.complete = true
    apply_winbar(self, self.winbar_text)
    for _, winid in ipairs(vim.fn.win_findbuf(self.bufnr)) do
      apply_window_options(self, winid)
    end
    if on_done then
      on_done()
    end
  end

  ---Insert the next chunk above the old lines and trim those, within one tick.
  ---@param first_tick boolean the first screen comes before trimming; later ticks trim first
  ---@return boolean done
  local function work(first_tick)
    local deadline = vim.uv.hrtime() + M.tick_ns
    local trimmed

    -- while reusing, the old lines are read and deleted from the front as entries take them
    if not first_tick and not self.stream then
      trimmed = trim_stale(self, deadline)
    end
    if next_item <= total then
      next_item = append_items(self, next_item, total, next_item == 1, deadline, true) + 1
    end
    if next_item > total then
      self.stream = nil
    end
    if not self.stream and (first_tick or not trimmed) then
      trimmed = trim_stale(self, deadline)
    end

    return trimmed and next_item > total
  end

  local function step()
    if self.generation ~= generation or not vim.api.nvim_buf_is_valid(self.bufnr) then
      return
    end
    if work(false) then
      finish()
      vim.notify("jlog: rendering done", vim.log.levels.INFO)

      return
    end
    vim.defer_fn(step, 0)
  end

  -- the old buffer is not replaced at once (~50ms at 500k lines): new lines go in above it and it is trimmed
  for _, winid in ipairs(vim.fn.win_findbuf(self.bufnr)) do
    -- a foldexpr would be re-evaluated on every insert and delete; finish sets the fold method again
    vim.wo[winid][0].foldmethod = "manual"
  end
  next_item = 1
  -- the first chunk is synchronous so the first screen shows at once; a view that fits in it is done
  if work(true) then
    finish()

    return
  end
  for _, winid in ipairs(vim.fn.win_findbuf(self.bufnr)) do
    show_first_header(self, winid)
  end
  -- one message when a render outlasts the first screen and one when it ends: each notify is a line in :messages
  vim.notify("jlog: rendering…", vim.log.levels.INFO)
  -- a timer, not vim.schedule: chained scheduled callbacks run back to back without handling input or redraw
  vim.defer_fn(step, 0)
end

---Extend a flat view in place with entries `indexes`; `refresh` is a shown last entry whose lines changed.
---@param indexes integer[]
---@param refresh integer|nil
View.append = function(self, indexes, refresh)
  local items, line_item = self.items, self.line_item
  local first = #items + 1
  local item_index, first_line, lines

  cache.drop(self)
  if refresh then
    item_index = self.entry_item[refresh]
    first_line = self.item_line[item_index]
    lines = item_lines(self, items[item_index], true)
    write_lines(self, first_line - 1, -1, lines)
    for line = first_line, math.max(#line_item, first_line + #lines - 1) do
      line_item[line] = line <= first_line + #lines - 1 and item_index or nil
    end
  end
  for _, index in ipairs(indexes) do
    items[#items + 1] = { kind = "entry", idx = index }
  end
  if #items >= first then
    -- an empty view still holds one blank line
    append_items(self, first, #items, #line_item == 0)
  end
end

---Copy list[first..last] to start at `dest`, safe for overlapping ranges that move up; selene's lua51 std rejects `table.move`.
---@param list any[]
---@param first integer
---@param last integer
---@param dest integer
local function move_up(list, first, last, dest)
  for offset = last - first, 0, -1 do
    list[dest + offset] = list[first + offset]
  end
end

---Extend a reversed flat view in place: `indexes` (newest first) go above the first line; `refresh` is the shown
---first entry whose lines changed.
---@param indexes integer[]
---@param refresh integer|nil
View.prepend = function(self, indexes, refresh)
  local items, line_item, item_line, entry_item = self.items, self.line_item, self.item_line, self.entry_item
  local count, old_items, old_lines = #indexes, #items, #line_item
  local old_span = 0
  local new_lines, new_line_item, new_item_line = {}, {}, {}

  cache.drop(self)
  local lines, delta

  if refresh then
    old_span = (item_line[2] or old_lines + 1) - item_line[1]
  end
  move_up(items, 1, old_items, count + 1)
  for position, index in ipairs(indexes) do
    items[position] = { kind = "entry", idx = index }
  end
  for position = 1, count + (refresh and 1 or 0) do
    lines = item_lines(self, items[position], true)
    new_item_line[position] = #new_lines + 1
    for _, line in ipairs(lines) do
      new_lines[#new_lines + 1] = line
      new_line_item[#new_lines] = position
    end
  end
  delta = #new_lines - old_span
  -- an empty view still holds one blank line
  write_lines(self, 0, old_lines == 0 and -1 or old_span, new_lines)

  move_up(line_item, old_span + 1, old_lines, #new_lines + 1)
  for line = #new_lines + 1, old_lines + delta do
    line_item[line] = line_item[line] + count
  end
  for line = 1, #new_lines do
    line_item[line] = new_line_item[line]
  end
  for position = old_items, 1, -1 do
    item_line[position + count] = item_line[position] + delta
  end
  for position, line in ipairs(new_item_line) do
    item_line[position] = line
  end
  for position = 1, old_items + count do
    entry_item[items[position].idx] = position
  end
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

  self.edited = true
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
  -- rewriting the group's first entry removed its header mark
  if starts_group(self, item_index) then
    place_header(self, item_index)
  end

  self:goto_entry(item.idx)
end

---Render entry `idx` from its entry again on the next render instead of reusing its old lines.
---@param idx integer entry index
View.forget = function(self, idx)
  self.entry_item[idx] = nil
  if self.stream then
    self.stream.entry_item[idx] = nil
  end
end

---Switch the whole view between compact and expanded, keeping the cursor on its entry.
---The mode left stays in a hidden buffer, so switching back shows it again without rendering.
View.toggle_mode = function(self)
  local idx = self:entry_at_cursor()
  local state = self.ws.state
  local cached = self.cache
  local items = self.items
  local left

  state.mode = state.mode == "expanded" and "compact" or "expanded"
  state.expanded = {}
  self.cache = nil
  if cached and cache.matches(cached, state.mode, items, self.ws.entries) then
    cache.keep_or_wipe(self, cache.swap(self, cached))
    if idx then
      self:goto_entry(idx)
    end

    return
  end
  if cached then
    cache.wipe(cached.bufnr)
  end

  if self.complete and not self.edited then
    -- render into a new buffer and keep this one for switching back
    left = cache.swap(self, cache.empty(create_buffer(self)))
  else
    -- every line changes, and the old lines were rendered in the other mode
    self.rendered_entries = nil
  end
  self:render(items, function()
    if idx then
      self:goto_entry(idx)
    end
  end)
  -- set after the render, which drops any cache it finds
  self.cache = left
  if idx then
    self:goto_entry(idx)
  end
end

---Wipe the cached buffer of the mode not shown.
View.drop_cache = function(self)
  cache.drop(self)
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
  local lines, bufnr

  if not entry then
    return
  end

  lines = vim.split(entry.raw, "\n", { plain = true })
  vim.list_extend(lines, entry.cont or {})
  bufnr = utils.open_float(lines, "raw")
  vim.b[bufnr].jlog_src = entry.src
  if entry.json_at then
    vim.bo[bufnr].filetype = "json"
  end
  keymaps.attach(bufnr, "raw", self.ws)
end

---@param text string
View.set_winbar = function(self, text)
  self.winbar_text = text
  apply_winbar(self, text)
end

---@param ws table workspace: `entries`, `opts`, `state = { mode, expanded }`, `format`
---@return JLogView
M.new = function(ws)
  local view = setmetatable({
    ws = ws,
    items = {},
    line_item = {},
    item_line = {},
    entry_item = {},
    generation = 0,
    winbar_text = "",
    redraw_spans = {},
    complete = false,
    edited = false,
    folded = {},
  }, View)

  view.bufnr = create_buffer(view)

  return view
end

---Fold level for `lnum` of the current buffer: a group's first entry line opens a fold, its other lines are inside it.
---@param lnum integer
---@return string
M.foldexpr = function(lnum)
  local view = views[vim.api.nvim_get_current_buf()]
  local item_index = view and view.line_item[lnum]

  if not item_index or not view.first_header then
    return "0"
  end
  if starts_group(view, item_index) and view.item_line[item_index] == lnum then
    return ">1"
  end

  return item_index > view.first_header and "1" or "0"
end

---Fold line of a closed group: its header, which the fold hides along with the group's lines.
---@return string|table
M.foldtext = function()
  local view = views[vim.api.nvim_get_current_buf()]
  local item_index = view and view.line_item[vim.v.foldstart]

  if not item_index or not starts_group(view, item_index) then
    return vim.fn.foldtext()
  end

  return { { (render.header(view.items[item_index - 1].group)), "JLogGroupHeader" } }
end

return M
