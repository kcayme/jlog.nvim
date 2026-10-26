-- Public API: setup, open and close, and the minimum Neovim version check.
local M = {}

local MIN_VERSION = "0.10"

---Whether this Neovim can run jlog; modules below rely on it (vim.uv, vim.json in worker threads, vim.system).
---@return boolean ok
---@return string|nil err
M.health_check = function()
  if vim.fn.has("nvim-" .. MIN_VERSION) == 0 then
    return false, "jlog requires Neovim >= " .. MIN_VERSION
  end

  return true
end

---@param opts table|nil partial `JLogOptions`
M.setup = function(opts)
  local _, err = M.health_check()

  if err then
    vim.notify(err, vim.log.levels.ERROR)

    return
  end
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
