-- :checkhealth jlog: whether this Neovim can run jlog.
local M = {}

---`:checkhealth jlog`: reports whether this Neovim can run jlog.
M.check = function()
  -- Neovim < 0.9 names these report_*, and an old Neovim is the one this check is for
  local report_start = vim.health.start or vim.health.report_start
  local report_ok = vim.health.ok or vim.health.report_ok
  local report_error = vim.health.error or vim.health.report_error
  local _, err = require("jlog").health_check()

  report_start("jlog")
  if err then
    report_error(err)

    return
  end
  report_ok("Neovim " .. tostring(vim.version()) .. " meets the minimum version")
end

return M
