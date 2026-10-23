local M = {}

---@class JLogHighlightGroup
---@field name string highlight group name
---@field link string group it links to by default

---Highlight groups and their default links (spec §6.3), in definition order.
---@type JLogHighlightGroup[]
M.GROUPS = {
  { name = "JLogTime", link = "Comment" },
  { name = "JLogLevelError", link = "DiagnosticError" },
  { name = "JLogLevelWarn", link = "DiagnosticWarn" },
  { name = "JLogLevelInfo", link = "DiagnosticInfo" },
  { name = "JLogLevelDebug", link = "DiagnosticHint" },
  { name = "JLogLevelTrace", link = "Comment" },
  { name = "JLogMessage", link = "Normal" },
  { name = "JLogKey", link = "Identifier" },
  { name = "JLogValue", link = "String" },
  { name = "JLogString", link = "String" },
  { name = "JLogNumber", link = "Number" },
  { name = "JLogBoolean", link = "Boolean" },
  { name = "JLogNull", link = "Constant" },
  { name = "JLogPrefix", link = "Comment" },
  { name = "JLogPlain", link = "Comment" },
  { name = "JLogGroupHeader", link = "Title" },
  { name = "JLogSectionHeader", link = "Title" },
  { name = "JLogFieldName", link = "Identifier" },
  { name = "JLogFieldCount", link = "Comment" },
  { name = "JLogWinbar", link = "WinBar" },
}

---Define every `JLog*` group as a default link, so user and colorscheme definitions win.
M.setup = function()
  for _, group in ipairs(M.GROUPS) do
    vim.api.nvim_set_hl(0, group.name, { link = group.link, default = true })
  end
end

return M
