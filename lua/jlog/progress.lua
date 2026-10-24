local config = require("jlog.config")

local M = {}

-- the first Neovim with progress messages (`nvim_echo` with `kind = "progress"`)
local PROGRESS_VERSION = "nvim-0.12"

---The workspace key of each message id whose work is still running; a workspace has one id per kind of work.
---@type table<string, string>
local running = {}

---@param ws_key string
---@param kind string
---@return string
local function id_of(ws_key, kind)
  return "jlog." .. kind .. "." .. ws_key
end

---@return boolean
local function use_progress()
  return config.options.progress == "auto" and vim.fn.has(PROGRESS_VERSION) == 1
end

---@param id string
---@param message string
---@param status "running"|"success"|"cancel"
local function echo(id, message, status)
  -- the done message is kept in :messages, like a notify; the running one is replaced by it
  vim.api.nvim_echo({ { message } }, status ~= "running", {
    kind = "progress",
    id = id,
    source = "jlog",
    title = "jlog",
    status = status,
    percent = status == "success" and 100 or nil,
  })
end

---Report that work of `kind` started in workspace `ws_key`; a newer start of the same kind takes over its message.
---@param ws_key string
---@param kind "load"|"index"|"apply"|"render"
---@param message string
M.begin = function(ws_key, kind, message)
  local id = id_of(ws_key, kind)

  -- untracked, so its finish and cancel report nothing either
  if config.options.progress == "off" then
    return
  end
  running[id] = ws_key
  if not use_progress() then
    vim.notify("jlog: " .. message, vim.log.levels.INFO)

    return
  end
  echo(id, message, "running")
end

---Report that work of `kind` is done, if its start was reported; otherwise nothing is shown.
---@param ws_key string
---@param kind "load"|"index"|"apply"|"render"
---@param message string
M.finish = function(ws_key, kind, message)
  local id = id_of(ws_key, kind)

  if not running[id] then
    return
  end
  running[id] = nil
  if not use_progress() then
    vim.notify("jlog: " .. message, vim.log.levels.INFO)

    return
  end
  echo(id, message, "success")
end

---End the running work of workspace `ws_key` without a done message, e.g. when it closes.
---@param ws_key string
M.cancel = function(ws_key)
  for id, key in pairs(running) do
    if key == ws_key then
      running[id] = nil
      if use_progress() then
        echo(id, "cancelled", "cancel")
      end
    end
  end
end

return M
