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

---@param opts table|nil partial `JLogOptions`
M.setup = function(opts)
  local options = require("jlog.config").setup(opts)

  M.set_highlights()
  require("jlog.hooks").register(options)
end

---Open (or focus) a workspace, even when detection fails.
---@param target string|integer|nil file path, buffer number, or nil for the current buffer
---@return JLogWorkspace|nil
---@return string|nil err
M.open = function(target)
  if type(target) == "string" then
    return require("jlog.workspace").open({ path = target, force = true })
  end

  return require("jlog.workspace").open({ bufnr = target or vim.api.nvim_get_current_buf(), force = true })
end

return M
