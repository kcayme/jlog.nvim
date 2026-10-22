local M = {}

---Highlight group -> default link (spec §6.3).
local HIGHLIGHTS = {
  JLogTime = "Comment",
  JLogLevelError = "DiagnosticError",
  JLogLevelWarn = "DiagnosticWarn",
  JLogLevelInfo = "DiagnosticInfo",
  JLogLevelDebug = "DiagnosticHint",
  JLogLevelTrace = "Comment",
  JLogMessage = "Normal",
  JLogKey = "Identifier",
  JLogValue = "String",
  JLogString = "String",
  JLogNumber = "Number",
  JLogBoolean = "Boolean",
  JLogNull = "Constant",
  JLogPrefix = "Comment",
  JLogPlain = "Comment",
  JLogGroupHeader = "Title",
  JLogSectionHeader = "Title",
  JLogFieldName = "Identifier",
  JLogFieldCount = "Comment",
  JLogWinbar = "WinBar",
}

---Define every `JLog*` group as a default link, so user and colorscheme definitions win.
M.set_highlights = function()
  for name, link in pairs(HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

return M
