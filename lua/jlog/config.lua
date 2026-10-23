---@class JLogFieldsOptions
---@field time string[]
---@field level string[]
---@field message string[]

---@alias JLogViewMode "compact"|"expanded"
---@alias JLogSort "asc"|"desc"

---@class JLogViewOptions
---@field mode JLogViewMode
---@field sort JLogSort

---@class JLogUnwrapOptions
---@field enable boolean
---@field max_depth integer

---@alias JLogSidebarPosition "left"|"right"

---@class JLogSidebarOptions
---@field width integer
---@field position JLogSidebarPosition

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
---@field focus_sidebar string|false
---@field toggle_sidebar string|false
---@field close string|false
---@field add_filter string|false
---@field group_by string|false

---@class JLogOptions
---@field fields JLogFieldsOptions
---@field view JLogViewOptions
---@field unwrap JLogUnwrapOptions
---@field sidebar JLogSidebarOptions
---@field facets JLogFacetsOptions
---@field paging JLogPagingOptions
---@field keymaps JLogKeymapsOptions

local M = {}

---@type JLogOptions
M.defaults = {
  fields = {
    time = { "time", "ts", "timestamp", "@timestamp" },
    level = { "level", "lvl", "severity" },
    message = { "msg", "message" },
  },
  view = { mode = "compact", sort = "desc" },
  unwrap = { enable = true, max_depth = 4 },
  sidebar = { width = 40, position = "right" },
  facets = { top_values = 10 },
  paging = { size = 100000, overlap = 2000 },
  keymaps = {
    toggle_entry = "<Tab>",
    toggle_mode = "E",
    raw = "gf",
    reverse = "R",
    next_entry = "]]",
    prev_entry = "[[",
    next_error = "]e",
    prev_error = "[e",
    focus_sidebar = "s",
    toggle_sidebar = "S",
    close = "q",
    add_filter = "<CR>",
    group_by = "g",
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
