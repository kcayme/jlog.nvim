local M = {}

---@class JLogHighlightGroup
---@field name string highlight group name
---@field link string group it links to by default; a badge takes its color from it instead
---@field badge boolean|nil drawn reversed: the link's color as the background

---Highlight groups and their default links, in definition order.
---@type JLogHighlightGroup[]
M.GROUPS = {
  { name = "JLogTime", link = "Comment" },
  { name = "JLogLevelError", badge = true, link = "DiagnosticError" },
  { name = "JLogLevelWarn", badge = true, link = "DiagnosticWarn" },
  { name = "JLogLevelInfo", badge = true, link = "DiagnosticInfo" },
  { name = "JLogLevelDebug", badge = true, link = "DiagnosticHint" },
  { name = "JLogLevelTrace", badge = true, link = "Comment" },
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
  { name = "JLogFieldStale", link = "NonText" },
  { name = "JLogHint", link = "Comment" },
  { name = "JLogWinbar", link = "WinBar" },
  { name = "JLogOverlap", link = "Comment" },
}

---The badge style of `group`, or nil when its link has no color to reverse.
---@param group JLogHighlightGroup
---@return vim.api.keyset.highlight|nil
local function badge(group)
  local colors = vim.api.nvim_get_hl(0, { name = group.link, link = false })

  if not colors.fg and not colors.ctermfg then
    return nil
  end

  return { fg = colors.fg, ctermfg = colors.ctermfg, reverse = true, bold = true, default = true }
end

---Define every `JLog*` group by default only, so user and colorscheme definitions win.
M.setup = function()
  for _, group in ipairs(M.GROUPS) do
    vim.api.nvim_set_hl(0, group.name, group.badge and badge(group) or { link = group.link, default = true })
  end
end

return M
