local M = {}

---@param opts table|nil partial `JLogOptions`
M.setup = function(opts)
  require("jlog.config").setup(opts)
  require("jlog.ui.highlights").setup()
  require("jlog.hooks").register()
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
