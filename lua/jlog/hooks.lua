-- Autocommands: re-applies the highlight groups when the colorscheme changes.
local M = {}

---(Re)create the `jlog` augroup: re-apply the highlight groups when the colorscheme changes.
M.register = function()
  local group = vim.api.nvim_create_augroup("jlog", { clear = true })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      require("jlog.ui.highlights").setup()
    end,
  })
end

return M
