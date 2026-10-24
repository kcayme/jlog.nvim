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

---@class JLogSidebarOptions
---@field width integer
---@field position JLogSidebarPosition
---@field field_colors boolean color each field name in FIELDS by field; false uses `JLogFieldName`
---@field style JLogFieldStyle default style of field names in FIELDS
---@field fields table<string, JLogSidebarField> per field path or role (`time`, `level`, `message`, `status`)
---@field pill JLogPillOptions caps of `pill` field names

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
  compact = { style = "plain", order = {}, fields = {}, pill = { left = "\238\130\182", right = "\238\130\180" } },
  view = { mode = "compact", sort = "desc", field_colors = true },
  unwrap = { enable = true, max_depth = 4 },
  sidebar = {
    width = 45,
    position = "right",
    field_colors = true,
    style = "plain",
    fields = {},
    pill = { left = "\238\130\182", right = "\238\130\180" },
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

---@param opts table|nil
---@return JLogOptions
M.setup = function(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  return M.options
end

return M
