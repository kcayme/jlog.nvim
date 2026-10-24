local M = {}

local DEBOUNCE_MS = 200
local TAIL_CHECK = 256
local POLL_MS = 500

---@param ws JLogWorkspace
local function debounce(ws)
  ws.timer:stop()
  ws.timer:start(
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      ws:reload()
    end)
  )
end

---Record what was read of the file, to tell an append from a rewrite later.
---@param ws JLogWorkspace
---@param text string
M.snapshot = function(ws, text)
  local newlines, pos = 0, 0

  ws.size = #text
  ws.complete = text == "" or text:sub(-1) == "\n"
  ws.check = text:sub(-TAIL_CHECK)
  while true do
    pos = text:find("\n", pos + 1, true)
    if not pos then
      break
    end
    newlines = newlines + 1
  end
  ws.next_lnum = newlines + 1
end

---The new complete lines of a jsonl file that only grew, or nil when it must be rebuilt; a partial last line waits.
---@param ws JLogWorkspace
---@return string|nil
M.read_appended = function(ws)
  local fd = vim.uv.fs_open(ws.path, "r", 438)
  local stat, check_len, tail, last_newline

  if not fd then
    return nil
  end
  stat = vim.uv.fs_fstat(fd)
  if stat and stat.size > ws.size and ws.complete then
    check_len = math.min(TAIL_CHECK, ws.size)
    if vim.uv.fs_read(fd, check_len, ws.size - check_len) == ws.check then
      tail = vim.uv.fs_read(fd, stat.size - ws.size, ws.size)
    end
  end
  vim.uv.fs_close(fd)
  if not tail then
    return nil
  end
  last_newline = tail:match(".*()\n")

  return last_newline and tail:sub(1, last_newline) or ""
end

---Move the snapshot past `tail`, the appended lines just read.
---@param ws JLogWorkspace
---@param tail string
M.advance = function(ws, tail)
  ws.size = ws.size + #tail
  ws.check = (ws.check .. tail):sub(-TAIL_CHECK)
  ws.next_lnum = ws.next_lnum + select(2, tail:gsub("\n", ""))
end

---@param ws JLogWorkspace
M.file = function(ws)
  local on_event, wait_for_file

  -- watch `ws.path`; while it is missing, poll until it comes back
  local function arm()
    local ok, err = ws.watcher:start(ws.path, {}, vim.schedule_wrap(on_event))

    if ok then
      return
    end
    if vim.uv.fs_stat(ws.path) then
      vim.notify("jlog: cannot watch " .. ws.path .. ": " .. tostring(err), vim.log.levels.WARN)

      return
    end
    wait_for_file()
  end

  wait_for_file = function()
    ws.poll:start(
      POLL_MS,
      POLL_MS,
      vim.schedule_wrap(function()
        if ws.closed or not vim.uv.fs_stat(ws.path) then
          return
        end
        ws.poll:stop()
        arm()
        debounce(ws)
      end)
    )
  end

  on_event = function(_, _, events)
    -- events queued before the watcher stopped can still arrive while waiting for the file
    if ws.closed or ws.poll:is_active() then
      return
    end
    -- an atomic save, a rotation or a delete: the handle still watches the old file
    if events and events.rename then
      ws.watcher:stop()
      if not vim.uv.fs_stat(ws.path) then
        vim.notify("jlog: " .. ws.path .. " is gone, waiting for it to come back", vim.log.levels.WARN)
        wait_for_file()

        return
      end
      arm()
    end
    debounce(ws)
  end

  ws.watcher = vim.uv.new_fs_event()
  ws.poll = vim.uv.new_timer()
  arm()
end

---@param ws JLogWorkspace
M.buffer = function(ws)
  vim.api.nvim_buf_attach(ws.bufnr, false, {
    on_lines = function()
      if ws.closed then
        return true
      end
      debounce(ws)
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = ws.augroup,
    buffer = ws.bufnr,
    callback = function()
      debounce(ws)
    end,
  })
end

return M
