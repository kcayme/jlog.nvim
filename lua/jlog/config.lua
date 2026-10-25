---@class JLogFieldsOptions
---@field time string[]
---@field level string[]
---@field message string[]
---@field status string[] aliases of the status-code field, colored by class

---@alias JLogFieldStyle "plain"|"inverted"|"pill"

---@class JLogFormatContext
---@field value string
---@field key string
---@field entry JLogEntry

---@class JLogCompactField
---@field style JLogFieldStyle|nil
---@field format (fun(ctx: JLogFormatContext): string, string|nil)|nil returns the text and an optional highlight group

---@class JLogPillOptions
---@field left string
---@field right string

---@class JLogCompactOptions
---@field style JLogFieldStyle default style of fields without their own
---@field order string[] field keys shown first in the compact line, in this order
---@field fields table<string, JLogCompactField> per field key or role (`time`, `level`, `message`, `status`)
---@field pill JLogPillOptions
---@field style_values string[] keys or roles whose value, not key, takes an inverted or pill style

---@alias JLogViewMode "compact"|"expanded"
---@alias JLogSort "asc"|"desc"

---@class JLogViewOptions
---@field mode JLogViewMode
---@field sort JLogSort
---@field field_colors boolean color each field's key by field, cycling through `JLogField1`..`JLogField8`; false uses `JLogKey`

---@class JLogUnwrapOptions
---@field enable boolean
---@field max_depth integer

---@alias JLogSidebarPosition "left"|"right"

---@class JLogSidebarFormatContext
---@field name string field path as FIELDS lists it
---@field distinct integer distinct values counted for the field

---@class JLogSidebarField
---@field style JLogFieldStyle|nil
---@field format (fun(ctx: JLogSidebarFormatContext): string, string|nil)|nil the name's text and an optional group

---@alias JLogSidebarSection "filters"|"group"|"sort"|"fields"

---@alias JLogFieldSort "alphabetical"|"count"

---@class JLogSidebarFieldsOptions
---@field colors boolean color each field name in FIELDS by field; false uses `JLogFieldName`
---@field style JLogFieldStyle default style of field names in FIELDS
---@field pill JLogPillOptions caps of `pill` field names
---@field styles table<string, JLogSidebarField> per field path or role (`time`, `level`, `message`, `status`)
---@field pinned string[] field paths or roles listed first in FIELDS, in this order
---@field sort JLogFieldSort the other fields: by name, or by entries once the counts are final

---@class JLogSidebarOptions
---@field width integer
---@field position JLogSidebarPosition
---@field fields JLogSidebarFieldsOptions how FIELDS shows its field names
---@field sections JLogSidebarSection[] sections in the order shown; one left out is hidden

---@class JLogFacetsOptions
---@field top_values integer

---@class JLogPagingOptions
---@field size integer source lines (jsonl) or array elements per page, before overlap
---@field overlap integer neighbouring source lines (jsonl, extended so an entry is never cut) or elements shown with a page

---Every key may be `false` to disable the mapping.
---@class JLogKeymapsOptions
---@field toggle_entry string|false
---@field toggle_mode string|false
---@field raw string|false
---@field reverse string|false
---@field next_entry string|false
---@field prev_entry string|false
---@field next_error string|false
---@field prev_error string|false
---@field next_page string|false
---@field prev_page string|false
---@field focus_sidebar string|false
---@field toggle_sidebar string|false
---@field close string|false
---@field add_filter string|false
---@field group_by string|false
---@field help string|false

---@alias JLogProgress "auto"|"notify"|"off"

---@class JLogOptions
---@field fields JLogFieldsOptions
---@field view JLogViewOptions
---@field unwrap JLogUnwrapOptions
---@field sidebar JLogSidebarOptions
---@field facets JLogFacetsOptions
---@field paging JLogPagingOptions
---@field keymaps JLogKeymapsOptions
---@field compact JLogCompactOptions
---@field progress JLogProgress `auto` (Neovim 0.12+ progress messages, else `vim.notify`), `notify` or `off`

local M = {}

---@type JLogOptions
M.defaults = {
  fields = {
    time = { "time", "ts", "timestamp", "@timestamp" },
    level = { "level", "lvl", "severity" },
    message = { "msg", "message" },
    status = { "status", "status_code" },
  },
  compact = {
    style = "plain",
    order = {},
    fields = {},
    pill = { left = "\238\130\182", right = "\238\130\180" },
    style_values = { "level", "status" },
  },
  view = { mode = "compact", sort = "desc", field_colors = true },
  unwrap = { enable = true, max_depth = 4 },
  sidebar = {
    width = 45,
    position = "right",
    fields = {
      colors = true,
      style = "plain",
      pill = { left = "\238\130\182", right = "\238\130\180" },
      styles = {},
      pinned = {},
      sort = "alphabetical",
    },
    sections = { "filters", "group", "sort", "fields" },
  },
  facets = { top_values = 10 },
  paging = { size = 100000, overlap = 2000 },
  progress = "auto",
  keymaps = {
    toggle_entry = "<CR>",
    toggle_mode = "E",
    raw = "gf",
    reverse = "R",
    next_entry = "]]",
    prev_entry = "[[",
    next_error = "]e",
    prev_error = "[e",
    next_page = "]p",
    prev_page = "[p",
    focus_sidebar = "s",
    toggle_sidebar = "S",
    close = "q",
    add_filter = "<CR>",
    group_by = "g",
    help = "?",
  },
}

---@type JLogOptions
M.options = vim.deepcopy(M.defaults)

local SIDEBAR_SECTIONS = { filters = true, group = true, sort = true, fields = true }

---@param message string
local function warn(message)
  vim.notify("jlog: " .. message, vim.log.levels.WARN)
end

---`sections` with unknown and repeated names dropped, or the default order when it is not a list; each problem warns.
---@param sections any
---@return JLogSidebarSection[]
local function checked_sections(sections)
  local checked, seen = {}, {}

  if type(sections) ~= "table" or not vim.islist(sections) then
    warn("sidebar.sections: expected a list of section names, using the default order")

    return vim.deepcopy(M.defaults.sidebar.sections)
  end
  for _, name in ipairs(sections) do
    if not SIDEBAR_SECTIONS[name] then
      warn(("sidebar.sections: unknown section %q"):format(tostring(name)))
    elseif seen[name] then
      warn(("sidebar.sections: %q is listed twice"):format(name))
    else
      seen[name] = true
      checked[#checked + 1] = name
    end
  end

  return checked
end

---@param opts table|nil
---@return JLogOptions
M.setup = function(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  M.options.sidebar.sections = checked_sections(M.options.sidebar.sections)

  return M.options
end

return M
