vim.api.nvim_create_user_command("JLog", function(cmd_opts)
  require("jlog.commands").run(cmd_opts.fargs)
end, {
  desc = "Open a jlog workspace, or act on the current one (filter, group, raw, close)",
  nargs = "*",
  complete = function(arg_lead, cmdline)
    return require("jlog.commands").complete(arg_lead, cmdline)
  end,
})

-- setup() is optional: auto-open and highlights work with the defaults, and a later setup() re-registers
require("jlog.ui.highlights").setup()
require("jlog.hooks").register(require("jlog.config").options)
