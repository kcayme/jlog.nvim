local workspace = require("jlog.workspace")

local M = {}

local SUBCOMMANDS = { "filter", "group", "page", "raw", "close" }

---Subcommand -> handler(ws, args), where args is the rest of the command line.
local ACTIONS = {
  filter = function(ws, args)
    if args == "" then
      ws:clear_filters()

      return
    end
    ws:add_filter(args)
  end,
  group = function(ws, args)
    ws:set_group(args ~= "" and args or nil)
  end,
  page = function(ws, args)
    local page = tonumber(args)

    if not page then
      vim.notify("jlog: :JLog page needs a page number", vim.log.levels.WARN)

      return
    end
    ws:goto_page(page)
  end,
  raw = function(ws)
    ws:open_raw(nil)
  end,
  close = function(ws)
    ws:close()
  end,
}

---@param target string|integer
local function open(target)
  local ws, err = require("jlog").open(target)

  if not ws then
    vim.notify("jlog: " .. tostring(err), vim.log.levels.ERROR)
  end
end

---`:JLog [path] | filter [clause] | group [field] | page N | raw | close`.
---@param fargs string[]
M.run = function(fargs)
  local action = ACTIONS[fargs[1]]
  local args = table.concat(fargs, " ", 2)
  local ws

  if not action then
    if #fargs == 0 then
      -- already in a workspace: nothing to open
      if not workspace.current() then
        open(vim.api.nvim_get_current_buf())
      end

      return
    end
    -- nargs=* splits on spaces: a path with unescaped spaces comes back as several args
    open(vim.fs.normalize(table.concat(fargs, " ")))

    return
  end

  ws = workspace.current()
  if not ws then
    vim.notify("jlog: no workspace in this tab", vim.log.levels.WARN)

    return
  end
  action(ws, args)
end

---Subcommands (and files) for the first argument, then field names of the current tab's workspace.
---@param arg_lead string
---@param cmdline string
---@return string[]
M.complete = function(arg_lead, cmdline)
  local words = vim.split(vim.trim(cmdline), "%s+")
  local position = #words + (cmdline:match("%s$") and 1 or 0)
  local candidates = {}
  local ws

  if position <= 2 then
    candidates = vim.list_extend(vim.deepcopy(SUBCOMMANDS), vim.fn.getcompletion(arg_lead, "file"))
  elseif position == 3 and (words[2] == "filter" or words[2] == "group") then
    ws = workspace.current()
    candidates = ws and ws:field_names() or {}
  end

  return vim.tbl_filter(function(candidate)
    return vim.startswith(candidate, arg_lead)
  end, candidates)
end

return M
