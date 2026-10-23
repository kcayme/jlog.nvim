local detect = require("jlog.parse.detect")
local workspace = require("jlog.workspace")

local M = {}

local HEAD_LIMIT = 65536

---@param path string
---@return string|nil
---@return string|nil err
local function read_head(path)
  local fd, err = vim.uv.fs_open(path, "r", 438)
  local data

  if not fd then
    return nil, err
  end
  data, err = vim.uv.fs_read(fd, HEAD_LIMIT, 0)
  vim.uv.fs_close(fd)

  return data, err
end

---Read `path` into `bufnr` the way `:edit` would have, had no BufReadCmd matched.
---@param bufnr integer
---@param path string
local function normal_read(bufnr, path)
  local escaped = vim.fn.fnameescape(path)

  -- re-reads of this buffer (`:edit!`) stay normal reads, even if the file has become a log meanwhile
  vim.b[bufnr].jlog_raw = true
  vim.api.nvim_buf_call(bufnr, function()
    local undolevels = vim.bo.undolevels

    if not vim.uv.fs_stat(path) then
      vim.cmd("doautocmd BufNewFile " .. escaped)

      return
    end
    vim.cmd("doautocmd BufReadPre " .. escaped)
    -- with undolevels=-1 the read leaves no undo history, as a normal read does (`:help clear-undo`)
    vim.bo.undolevels = -1
    -- in case a reload left the old text in place
    vim.cmd("silent %delete _")
    vim.cmd("silent keepalt read ++edit " .. vim.v.cmdarg .. " " .. escaped)
    vim.cmd("silent 1delete _")
    vim.bo.undolevels = undolevels
    vim.bo.modified = false
    vim.cmd("doautocmd BufReadPost " .. escaped)
  end)
end

---Put every window still showing the placeholder back on its previous buffer (the workspace took a new tab).
---@param bufnr integer
local function release_placeholder(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.api.nvim_win_call(winid, function()
      local previous = vim.fn.bufnr("#")

      if previous > 0 and previous ~= bufnr and pcall(vim.cmd.buffer, previous) then
        return
      end
      vim.cmd.enew()
    end)
  end
end

---Open a workspace in place of the buffer being read, when the file is a recognized log.
---@param bufnr integer
---@param path string
---@param opts JLogOptions
---@return boolean opened
local function try_open(bufnr, path, opts)
  local bo = vim.bo[bufnr]
  local head, ws, err

  -- a normal buffer for the file (read before, or opened raw) is being reloaded: keep it one
  if vim.b[bufnr].jlog_raw then
    return false
  end
  head = read_head(path)
  if not head or not detect.detect(head, opts) then
    return false
  end

  -- the placeholder is named after the file: make sure no `:w` can ever write it over the file
  bo.buftype = "nofile"
  bo.bufhidden = "wipe"
  bo.swapfile = false
  bo.modifiable = false
  ws, err = workspace.open({ path = path })
  if not ws then
    error(err)
  end
  vim.schedule(function()
    release_placeholder(bufnr)
  end)

  return true
end

---@param event {buf: integer}
---@param opts JLogOptions
local function on_read(event, opts)
  local bufnr = event.buf
  local path = vim.api.nvim_buf_get_name(bufnr)
  local ok, opened = pcall(try_open, bufnr, path, opts)

  if ok and opened then
    return
  end
  if not ok then
    vim.notify("jlog: opening normally after an error: " .. tostring(opened), vim.log.levels.WARN)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.bo[bufnr].buftype = ""
    vim.bo[bufnr].bufhidden = ""
    vim.bo[bufnr].swapfile = vim.go.swapfile
    vim.bo[bufnr].modifiable = true
  end
  normal_read(bufnr, path)
end

---(Re)create the `jlog` augroup: highlights on ColorScheme, and auto-open when enabled.
---@param opts JLogOptions
M.register = function(opts)
  local group = vim.api.nvim_create_augroup("jlog", { clear = true })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      require("jlog.ui.highlights").setup()
    end,
  })
  if not opts.auto_open.enable then
    return
  end
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = opts.auto_open.patterns,
    -- let the events a normal read fires (FileType, BufEnter of the workspace, ...) run as usual
    nested = true,
    callback = function(event)
      on_read(event, opts)
    end,
  })
end

return M
