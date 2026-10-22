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
local Sidebar = {}
Sidebar.__index = Sidebar

local M = {}

local HEADERS = { filters = "FILTERS", group = "GROUP BY", fields = "FIELDS" }
local INLINE_VALUES = 3
local NAME_WIDTH = 14

local ns = vim.api.nvim_create_namespace("jlog.filter")
local hl_ns = vim.api.nvim_create_namespace("jlog.sidebar")

---@type table<integer, JLogSidebar>
local sidebars = {}

---Facet values may hold newlines, which buffer lines cannot.
---@param value string
---@return string
local function display(value)
  return (value:gsub("\n", "\\n"))
end

---@param facet JLogFacet
---@return string
local function summary(facet)
  local parts = {}

  if facet.distinct > INLINE_VALUES then
    return facet.distinct .. (facet.capped and "+" or "") .. " values"
  end
  for _, top in ipairs(facet.top) do
    parts[#parts + 1] = display(top.value) .. " (" .. top.count .. ")"
  end

  return table.concat(parts, "  ")
end

---`field=value`, quoting the value when the filter parser needs it.
---@param name string
---@param value string
---@return string
local function clause(name, value)
  if value ~= "" and not value:find('[%s"]') then
    return name .. "=" .. value
  end

  return name .. '="' .. value:gsub('[\\"]', "\\%0") .. '"'
end

---@param sidebar JLogSidebar
---@param lines string[]
---@param highlights {[1]: integer, [2]: integer, [3]: integer, [4]: string}[] row, start col, end col, group
local function add_fields(sidebar, lines, highlights)
  local name_text

  for _, facet in ipairs(sidebar.facets) do
    name_text = string.format("%-" .. NAME_WIDTH .. "s", facet.name)
    lines[#lines + 1] = (sidebar.expanded[facet.name] and "▾ " or "▸ ") .. name_text .. "  " .. summary(facet)
    sidebar.rows[#lines] = { name = facet.name }
    highlights[#highlights + 1] = { #lines - 1, 4, 4 + #facet.name, "JLogFieldName" }

    if sidebar.expanded[facet.name] then
      for _, top in ipairs(facet.top) do
        lines[#lines + 1] = "  " .. display(top.value) .. " (" .. top.count .. ")"
        sidebar.rows[#lines] = { name = facet.name, value = top.value }
        highlights[#highlights + 1] = { #lines - 1, #lines[#lines] - #tostring(top.count) - 2, -1, "JLogFieldCount" }
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

---Rewrite the buffer from the workspace state and the last facets. Edits inside FIELDS are discarded.
Sidebar.render = function(self)
  local state = self.ws.state
  local lines = { HEADERS.filters }
  local highlights = {}
  local diagnostics = {}

  self.rows = {}
  vim.list_extend(lines, state.filters)
  for _, err in ipairs(self.errors) do
    lines[#lines + 1] = err.text
    diagnostics[#diagnostics + 1] =
      { lnum = #lines - 1, col = 0, severity = vim.diagnostic.severity.WARN, message = err.msg, source = "jlog" }
  end
  vim.list_extend(lines, { "", HEADERS.group })
  if state.group then
    lines[#lines + 1] = state.group
  end
  vim.list_extend(lines, { "", HEADERS.fields })
  add_fields(self, lines, highlights)

  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  vim.bo[self.bufnr].modified = false
  vim.diagnostic.set(ns, self.bufnr, diagnostics)

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
  end
end

---@param text string trimmed line
---@return boolean
local function ends_sections(text)
  return text == HEADERS.fields or vim.startswith(text, "▸") or vim.startswith(text, "▾")
end

---Filters (non-blank lines under FILTERS, or before any header) and the group field (first non-blank line under
---GROUP BY). Reading stops at FIELDS or the first facet line. Without a GROUP BY header there is no group, and
---the filters end at the first blank line, so a former group line never turns into a filter.
---@return {filters: string[], group: string|nil}
Sidebar.read = function(self)
  local spec = { filters = {} }
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
  local has_group = false
  local section = "filters"
  local text

  for _, line in ipairs(lines) do
    text = vim.trim(line)
    if ends_sections(text) then
      break
    end
    has_group = has_group or text == HEADERS.group
  end

  for _, line in ipairs(lines) do
    text = vim.trim(line)
    if ends_sections(text) then
      break
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

  -- the error lines are in `spec.filters` again; apply re-validates them
  self.errors = {}
  self.ws.state.filters = spec.filters
  self.ws.state.group = spec.group
  self.ws:apply()
  vim.bo[self.bufnr].modified = false
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
  self.ws:set_group(row.name)

  return true
end

---@param ws table workspace
---@return JLogSidebar
M.new = function(ws)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local sidebar = setmetatable({ bufnr = bufnr, ws = ws, facets = {}, expanded = {}, errors = {}, rows = {} }, Sidebar)

  vim.bo[bufnr].buftype = "acwrite"
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
      if vim.bo[bufnr].modified then
        sidebar:sync()
      end
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

return M
