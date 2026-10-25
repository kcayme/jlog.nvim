local facets_mod = require("jlog.query.facets")
local field_label = require("jlog.ui.field_label")
local field_order = require("jlog.ui.field_order")
local filter = require("jlog.query.filter")
local keymaps = require("jlog.ui.keymaps")

---@class JLogFilterError
---@field text string the filter line as written
---@field msg string

---@class JLogSidebarRow
---@field name string field path
---@field value string|nil facet value; nil on the field's own line

---@class JLogSidebar
---@field bufnr integer
---@field ws table workspace
---@field facets JLogFacet[] from the last apply that had the sidebar shown
---@field expanded table<string, boolean> unfolded field names
---@field errors JLogFilterError[] filter lines that failed to parse; shown after the valid ones until edited
---@field rows table<integer, JLogSidebarRow> buffer line (1-based) -> FIELDS row
---@field width integer|nil text cells the FIELDS lines were last fitted to
---@field stale boolean the facets are the last apply's, kept while the current apply counts its own
local Sidebar = {}
Sidebar.__index = Sidebar

local M = {}

local HEADERS = { filters = "FILTERS", group = "GROUP BY", fields = "FIELDS" }
local COUNTING = "counting…"
local INLINE_VALUES = 3
local NAME_WIDTH = 14
-- cells left empty at the right edge, so field lines do not run into the window border
local RIGHT_PADDING = 2

local HINTS = { [HEADERS.filters] = "status>=500 level=ERROR -health", [HEADERS.group] = "request_id" }

local ns = vim.api.nvim_create_namespace("jlog.filter")
local hl_ns = vim.api.nvim_create_namespace("jlog.sidebar")
local sort_ns = vim.api.nvim_create_namespace("jlog.sort")
local hint_ns = vim.api.nvim_create_namespace("jlog.hint")

---@type table<integer, JLogSidebar>
local sidebars = {}

---Facet values may hold newlines, which buffer lines cannot.
---@param value string
---@return string
local function display(value)
  return (value:gsub("\n", "\\n"))
end

---`text` cut to at most `width` display cells, ending in `…` when cut.
---@param text string
---@param width integer
---@return string
local function truncate(text, width)
  local chars

  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  if width < 1 then
    return ""
  end
  chars = vim.fn.strchars(text)
  repeat
    chars = math.min(chars - 1, width - 1)
    text = vim.fn.strcharpart(text, 0, chars)
  until vim.fn.strdisplaywidth(text) <= width - 1

  return text .. "…"
end

---The count as shown, with `~` ahead of an estimate.
---@param facet JLogFacet
---@param count integer
---@return string
local function count_text(facet, count)
  return (facet.estimated and "~" or "") .. count
end

---`value (count)`, the value cut so the whole fits in `width` cells.
---@param value string
---@param count string
---@param width integer
---@return string
local function counted(value, count, width)
  local suffix = " (" .. count .. ")"

  return truncate(display(value), width - #suffix) .. suffix
end

---The inline values of a field line, or their number when there are many or they do not fit in `width` cells.
---@param facet JLogFacet
---@param width integer
---@return string
local function summary(facet, width)
  local parts = {}
  local text

  if facet.distinct == 1 then
    return counted(facet.top[1].value, count_text(facet, facet.top[1].count), width)
  end
  if facet.distinct <= INLINE_VALUES then
    for _, top in ipairs(facet.top) do
      parts[#parts + 1] = display(top.value) .. " (" .. count_text(facet, top.count) .. ")"
    end
    text = table.concat(parts, "  ")
    if vim.fn.strdisplaywidth(text) <= width then
      return text
    end
  end

  return facet.distinct .. (facet.capped and "+" or "") .. " values"
end

---`field=value`, quoting the value when the filter parser needs it; a newline is written as `\n`.
---@param name string
---@param value string
---@return string
local function clause(name, value)
  name = filter.escape_field(name)
  if value ~= "" and not value:find('[%s"]') then
    return name .. "=" .. value
  end

  return name .. '="' .. value:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
end

---Text cells field lines may fill: the sidebar window's (or the configured width while hidden), less the padding.
---@param sidebar JLogSidebar
---@return integer
local function text_width(sidebar)
  local winid = vim.fn.bufwinid(sidebar.bufnr)

  if winid == -1 then
    return sidebar.ws.opts.sidebar.width - RIGHT_PADDING
  end

  return vim.api.nvim_win_get_width(winid) - vim.fn.getwininfo(winid)[1].textoff - RIGHT_PADDING
end

---@param sidebar JLogSidebar
---@param lines string[]
---@param highlights {[1]: integer, [2]: integer, [3]: integer, [4]: string, [5]: string|nil}[] row, cols, group, cap
---@param width integer text cells of the sidebar window
local function add_fields(sidebar, lines, highlights, width)
  local count_group = sidebar.stale and "JLogFieldStale" or "JLogFieldCount"
  local opts = sidebar.ws.opts
  local pill = opts.sidebar.fields.pill
  local name, group, cap_group, caps
  local head
  local count

  for _, facet in ipairs(sidebar.facets) do
    name, group, cap_group = field_label.of(opts, facet.name, facet.distinct)
    -- a pill's caps are inline virtual text: they take cells the padding and the line width give up
    caps = cap_group and vim.fn.strdisplaywidth(pill.left .. pill.right) or 0
    head = (sidebar.expanded[facet.name] and "▾ " or "▸ ")
      .. name
      .. string.rep(" ", NAME_WIDTH - caps - vim.fn.strdisplaywidth(name))
      .. "  "
    lines[#lines + 1] = truncate(head .. summary(facet, width - caps - vim.fn.strdisplaywidth(head)), width - caps)
    sidebar.rows[#lines] = { name = facet.name }
    highlights[#highlights + 1] = { #lines - 1, 4, math.min(4 + #name, #lines[#lines]), group, cap_group }
    if sidebar.stale then
      highlights[#highlights + 1] = { #lines - 1, math.min(#head, #lines[#lines]), -1, count_group }
    end

    if sidebar.expanded[facet.name] then
      for _, top in ipairs(facet.top) do
        count = count_text(facet, top.count)
        lines[#lines + 1] = "  " .. counted(top.value, count, width - 2)
        sidebar.rows[#lines] = { name = facet.name, value = top.value }
        highlights[#highlights + 1] = { #lines - 1, #lines[#lines] - #count - 2, -1, count_group }
      end
    end
  end
end

---@return JLogSidebarRow|nil
Sidebar.row_at_cursor = function(self)
  if vim.api.nvim_get_current_buf() ~= self.bufnr then
    return nil
  end

  return self.rows[vim.api.nvim_win_get_cursor(0)[1]]
end

---The FIELDS row showing `anchor`'s value, else its field line.
---@param rows table<integer, JLogSidebarRow>
---@param anchor JLogSidebarRow
---@return integer|nil
local function find_row(rows, anchor)
  local field_row

  for row, target in pairs(rows) do
    if target.name == anchor.name and target.value == anchor.value then
      return row
    end
    if target.name == anchor.name and not target.value then
      field_row = row
    end
  end

  return field_row
end

---@param opts JLogOptions
---@param name JLogSidebarSection
---@return boolean
local function shows(opts, name)
  return vim.tbl_contains(opts.sidebar.sections, name)
end

---Show how to apply on the first row and, outside insert mode, an example on each blank section line.
---@param sidebar JLogSidebar
---@param insert boolean
local function show_hints(sidebar, insert)
  local bufnr = sidebar.bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local opts = sidebar.ws.opts
  local help = opts.keymaps.help
  local editable = shows(opts, "filters") or shows(opts, "group")
  -- here rather than in the winbar, which statusline plugins such as lualine take over
  local parts = vim.tbl_filter(function(part)
    return part ~= ""
  end, { editable and ":w to apply" or "", help and (help .. " help") or "" })
  local how = table.concat(parts, " | ")
  local text, hint

  vim.api.nvim_buf_clear_namespace(bufnr, hint_ns, 0, -1)
  if how ~= "" then
    vim.api.nvim_buf_set_extmark(bufnr, hint_ns, 0, 0, {
      virt_text = { { how, "JLogHint" }, { string.rep(" ", RIGHT_PADDING) } },
      virt_text_pos = "right_align",
    })
  end
  for row, line in ipairs(lines) do
    text = vim.trim(line)
    hint = HINTS[text]
    if hint and not insert and lines[row + 1] and vim.trim(lines[row + 1]) == "" then
      vim.api.nvim_buf_set_extmark(bufnr, hint_ns, row, 0, { virt_text = { { hint, "JLogHint" } } })
    end
  end
end

---Draw a pill field name's caps as inline virtual text around its highlight `hl`, if it has a cap group.
---@param sidebar JLogSidebar
---@param hl {[1]: integer, [2]: integer, [3]: integer, [4]: string, [5]: string|nil}
local function add_caps(sidebar, hl)
  local pill = sidebar.ws.opts.sidebar.fields.pill

  if not hl[5] then
    return
  end
  if pill.left ~= "" then
    vim.api.nvim_buf_set_extmark(sidebar.bufnr, hl_ns, hl[1], hl[2], {
      virt_text = { { pill.left, hl[5] } },
      virt_text_pos = "inline",
    })
  end
  if pill.right ~= "" then
    vim.api.nvim_buf_set_extmark(sidebar.bufnr, hl_ns, hl[1], hl[3], {
      virt_text = { { pill.right, hl[5] } },
      virt_text_pos = "inline",
    })
  end
end

---Rewrite the buffer from state and facets; FIELDS edits are discarded and a FIELDS cursor stays on its row.
---@param progress string|nil shown after the FIELDS header while the counts are partial
Sidebar.render = function(self, progress)
  local state = self.ws.state
  -- the first row is left blank for how to apply edits, drawn over it by `show_hints`
  local lines = { "" }
  local in_buffer = 0
  local highlights = {}
  local diagnostics = {}
  local width = text_width(self)
  local winid = vim.fn.bufwinid(self.bufnr)
  local cursor = winid ~= -1 and vim.api.nvim_win_get_cursor(winid)
  local anchor = cursor and self.rows[cursor[1]]
  local fields_row, anchor_row

  progress = progress or (self.stale and COUNTING or nil)
  self.width = width
  self.rows = {}
  for _, section in ipairs(self.ws.opts.sidebar.sections) do
    -- SORT is virtual lines, drawn by `show_sort`; the other sections are buffer text, a blank line apart
    if section ~= "sort" then
      in_buffer = in_buffer + 1
      if in_buffer > 1 then
        lines[#lines + 1] = ""
      end
    end
    if section == "filters" then
      lines[#lines + 1] = HEADERS.filters
      vim.list_extend(lines, state.filters)
      for _, err in ipairs(self.errors) do
        lines[#lines + 1] = err.text
        diagnostics[#diagnostics + 1] =
          { lnum = #lines - 1, col = 0, severity = vim.diagnostic.severity.WARN, message = err.msg, source = "jlog" }
      end
      -- an empty section keeps a blank input line
      if #state.filters == 0 and #self.errors == 0 then
        lines[#lines + 1] = ""
      end
    elseif section == "group" then
      vim.list_extend(lines, { HEADERS.group, state.group or "" })
    elseif section == "fields" then
      lines[#lines + 1] = HEADERS.fields
      fields_row = #lines
      add_fields(self, lines, highlights, width)
    end
  end

  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  vim.bo[self.bufnr].modified = false
  vim.diagnostic.set(ns, self.bufnr, diagnostics)
  anchor_row = anchor and find_row(self.rows, anchor)
  if anchor_row then
    vim.api.nvim_win_set_cursor(winid, { anchor_row, cursor[2] })
  end

  vim.api.nvim_buf_clear_namespace(self.bufnr, hl_ns, 0, -1)
  for row, line in ipairs(lines) do
    if line == HEADERS.filters or line == HEADERS.group or line == HEADERS.fields then
      highlights[#highlights + 1] = { row - 1, 0, -1, "JLogSectionHeader" }
    end
  end
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(self.bufnr, hl_ns, hl[1], hl[2], {
      end_col = hl[3] == -1 and #lines[hl[1] + 1] or hl[3],
      hl_group = hl[4],
    })
    add_caps(self, hl)
  end
  if progress and fields_row then
    vim.api.nvim_buf_set_extmark(self.bufnr, hl_ns, fields_row - 1, 0, {
      virt_text = { { "  " .. progress, self.stale and "JLogFieldStale" or "JLogFieldCount" } },
    })
  end
  -- a reload can render while the user types in the sidebar
  show_hints(self, vim.api.nvim_get_current_buf() == self.bufnr and vim.fn.mode():find("^[iR]") ~= nil)
  self:show_sort()
end

---@class JLogSidebarUpdate
---@field counter JLogFacetCounter|nil new field counts to show
---@field partial boolean|nil the counts are still coming in (loading, or lines appended since the last apply)
---@field progress string|nil shown after the FIELDS header, e.g. `loading 40%`

---Take new field counts if given, then redraw; unapplied FILTERS or GROUP BY edits are kept, only SORT follows them.
---@param update JLogSidebarUpdate|nil
Sidebar.refresh = function(self, update)
  local ws = self.ws
  local counter = update and update.counter
  local final

  if counter then
    final = not update.partial and not ws.loading
    self.facets = field_order.order(facets_mod.result(counter, ws.opts.facets.top_values), ws.opts, self.facets, final)
    for _, facet in ipairs(self.facets) do
      ws.fields_seen[facet.name] = true
    end
    ws.published.names = #counter.names
  end
  if vim.bo[self.bufnr].modified then
    self:show_sort()

    return
  end
  self:render(update and update.progress)
end

---Show the order as virtual lines (never in the buffer or `:w`): above the next section's header, else below the end.
Sidebar.show_sort = function(self)
  local sections = self.ws.opts.sidebar.sections
  local key = self.ws.opts.keymaps.reverse
  local newest_first = self.ws.stored_newest_first ~= self.ws.state.reverse
  local order = (newest_first and "newest first" or "oldest first") .. (key and (" (" .. key .. ")") or "")
  local sort_line = { { "SORT", "JLogSectionHeader" }, { "  " .. order, "JLogHint" } }
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
  local position = vim.fn.index(sections, "sort") + 1
  local next_header = sections[position + 1] and HEADERS[sections[position + 1]]

  vim.api.nvim_buf_clear_namespace(self.bufnr, sort_ns, 0, -1)
  if position == 0 then
    return
  end
  for row, line in ipairs(lines) do
    if next_header and vim.trim(line) == next_header then
      vim.api.nvim_buf_set_extmark(self.bufnr, sort_ns, row - 1, 0, {
        virt_lines = { sort_line, {} },
        virt_lines_above = true,
      })

      return
    end
  end
  -- last, or the header after it was deleted by an edit
  vim.api.nvim_buf_set_extmark(self.bufnr, sort_ns, #lines - 1, 0, { virt_lines = { {}, sort_line } })
end

---Filters and group typed under their headers, wherever those are; without a GROUP BY header a blank ends filters.
---@return {filters: string[], group: string|nil}
Sidebar.read = function(self)
  local spec = { filters = {} }
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
  local has_group = false
  local section
  local text

  for _, line in ipairs(lines) do
    has_group = has_group or vim.trim(line) == HEADERS.group
  end

  for _, line in ipairs(lines) do
    text = vim.trim(line)
    if text == HEADERS.fields then
      section = nil
    elseif text == HEADERS.filters then
      section = "filters"
    elseif text == HEADERS.group then
      section = "group"
    elseif text == "" then
      if not has_group and section == "filters" then
        section = nil
      end
    elseif section == "filters" then
      spec.filters[#spec.filters + 1] = text
    elseif section == "group" and not spec.group then
      spec.group = text
    end
  end

  return spec
end

---@param errors JLogFilterError[]
Sidebar.set_errors = function(self, errors)
  self.errors = errors
end

---Apply what the user typed in FILTERS and GROUP BY.
Sidebar.sync = function(self)
  local spec = self:read()
  local opts = self.ws.opts

  -- a hidden section was not typed in: its filters or group stay as the field actions and commands set them
  if shows(opts, "filters") then
    -- the error lines are in `spec.filters` again; apply re-validates them
    self.errors = {}
    self.ws.state.filters = spec.filters
  end
  if shows(opts, "group") then
    self.ws.state.group = spec.group
  end
  -- applied now, so the apply may rewrite the buffer
  vim.bo[self.bufnr].modified = false
  self.ws:apply()
end

---@param name string
---@param expand boolean|nil default true
Sidebar.expand_field = function(self, name, expand)
  self.expanded[name] = expand ~= false or nil
  self:render()
end

---Focus the sidebar and put the cursor on `name`'s field line, or on its `value` line when given.
---@param name string
---@param value string|nil
Sidebar.cursor_to_value = function(self, name, value)
  self.ws:focus_sidebar()
  for row, target in pairs(self.rows) do
    if target.name == name and target.value == value then
      vim.api.nvim_win_set_cursor(0, { row, 0 })

      return
    end
  end
end

---`<CR>`: on a value, add it as a filter; on a field name, fold/unfold it.
---@return boolean handled
Sidebar.activate = function(self)
  local row = self:row_at_cursor()

  if not row then
    return false
  end
  if row.value then
    self.ws:add_filter(clause(row.name, row.value))
  else
    self:expand_field(row.name, not self.expanded[row.name])
  end

  return true
end

---`g`: on a field name, group by it.
---@return boolean handled
Sidebar.group_at_cursor = function(self)
  local row = self:row_at_cursor()

  if not row or row.value then
    return false
  end
  self.ws:set_group(filter.escape_field(row.name))

  return true
end

---@param ws table workspace
---@return JLogSidebar
M.new = function(ws)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local sidebar =
    setmetatable({ bufnr = bufnr, ws = ws, facets = {}, expanded = {}, errors = {}, rows = {}, stale = false }, Sidebar)

  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].filetype = "jlog_sidebar"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].omnifunc = "v:lua.require'jlog.ui.sidebar'.omnifunc"
  vim.api.nvim_buf_set_name(bufnr, "jlog-sidebar://" .. ws.key)

  sidebars[bufnr] = sidebar
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = function()
      sidebar:sync()
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = bufnr,
    callback = function()
      show_hints(sidebar, false)
      if vim.bo[bufnr].modified then
        sidebar:sync()
      end
    end,
  })
  vim.api.nvim_create_autocmd("InsertEnter", {
    buffer = bufnr,
    callback = function()
      show_hints(sidebar, true)
    end,
  })
  vim.api.nvim_create_autocmd("TextChanged", {
    buffer = bufnr,
    callback = function()
      show_hints(sidebar, false)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    callback = function()
      sidebars[bufnr] = nil
    end,
  })
  keymaps.attach(bufnr, "sidebar", ws)

  return sidebar
end

---Completes field names (`ws:field_names()`) in the sidebar.
---@param findstart integer
---@param base string
---@return integer|string[]
M.omnifunc = function(findstart, base)
  local line, start
  local sidebar = sidebars[vim.api.nvim_get_current_buf()]

  if findstart == 1 then
    line = vim.api.nvim_get_current_line()
    start = vim.api.nvim_win_get_cursor(0)[2]
    while start > 0 and line:sub(start, start):match("[%w_%.@-]") do
      start = start - 1
    end
    -- a leading `-` negates the term; it is not part of the field name
    if line:sub(start + 1, start + 1) == "-" then
      start = start + 1
    end

    return start
  end
  if not sidebar then
    return {}
  end

  return vim.tbl_filter(function(name)
    return vim.startswith(name, base)
  end, sidebar.ws:field_names())
end

-- refit FIELDS to a resized sidebar; one with unsaved FILTERS/GROUP BY edits keeps them until it is synced
vim.api.nvim_create_autocmd("WinResized", {
  group = vim.api.nvim_create_augroup("jlog.sidebar", { clear = true }),
  callback = function()
    for bufnr, sidebar in pairs(sidebars) do
      if vim.fn.bufwinid(bufnr) ~= -1 and not vim.bo[bufnr].modified and text_width(sidebar) ~= sidebar.width then
        sidebar:render()
      end
    end
  end,
})

return M
