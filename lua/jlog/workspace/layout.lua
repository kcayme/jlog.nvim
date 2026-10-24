local M = {}

---An empty, unmodified buffer, unnamed or named after the file (e.g. a buffer for a file that did not exist yet).
---@param bufnr integer
---@param path string|nil
---@return boolean
local function is_placeholder(bufnr, path)
  local name = vim.api.nvim_buf_get_name(bufnr)

  return (name == "" or name == path)
    and not vim.bo[bufnr].modified
    and vim.api.nvim_buf_line_count(bufnr) == 1
    and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ""
end

---Wipe empty, unmodified buffers named `path`: `:tabedit` would reuse one unread and `:w` would truncate the file.
---@param path string
local function wipe_placeholders(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_get_name(bufnr) == path
      and vim.api.nvim_buf_is_loaded(bufnr)
      and is_placeholder(bufnr, path)
    then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

---@param ws JLogWorkspace
---@return integer winid
local function open_sidebar_window(ws)
  local winid = vim.api.nvim_open_win(ws.sidebar.bufnr, false, {
    split = ws.opts.sidebar.position,
    win = M.window_in_tab(ws, ws.view.bufnr) or vim.api.nvim_tabpage_get_win(ws.tab),
    width = ws.opts.sidebar.width,
  })
  local wo = vim.wo[winid][0]

  wo.number = false
  wo.relativenumber = false
  wo.wrap = false
  wo.winfixwidth = true

  return winid
end

---@param ws JLogWorkspace
---@param bufnr integer
---@return integer|nil
M.window_in_tab = function(ws, bufnr)
  if not vim.api.nvim_tabpage_is_valid(ws.tab) then
    return nil
  end
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(ws.tab)) do
    if vim.api.nvim_win_get_buf(winid) == bufnr then
      return winid
    end
  end

  return nil
end

---@param ws JLogWorkspace
---@param path string|nil
M.create = function(ws, path)
  local current_win = vim.api.nvim_get_current_win()
  local reuse = #vim.api.nvim_tabpage_list_wins(0) == 1 and is_placeholder(vim.api.nvim_win_get_buf(current_win), path)
  local view_win

  if not reuse then
    vim.cmd("tabnew")
  end
  -- wipe the empty buffer once the view replaces it: a kept one would let `:tabedit` then `:w` truncate the file
  vim.bo.bufhidden = "wipe"
  ws.tab = vim.api.nvim_get_current_tabpage()
  view_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(view_win, ws.view.bufnr)
  open_sidebar_window(ws)
  vim.api.nvim_set_current_win(view_win)
end

---@param ws JLogWorkspace
M.focus_sidebar = function(ws)
  local winid = M.window_in_tab(ws, ws.sidebar.bufnr)

  if not winid then
    winid = open_sidebar_window(ws)
    -- facets are skipped while the sidebar is hidden
    ws:apply()
  end
  vim.api.nvim_set_current_win(winid)
end

---@param ws JLogWorkspace
M.toggle_sidebar = function(ws)
  local winid = M.window_in_tab(ws, ws.sidebar.bufnr)

  if not winid then
    open_sidebar_window(ws)
    ws:apply()

    return
  end
  pcall(vim.api.nvim_win_close, winid, false)
end

---Open the source as a normal buffer in a new tab, at `lnum`. The only way jlog opens a raw file.
---@param ws JLogWorkspace
---@param lnum integer|nil
M.open_raw = function(ws, lnum)
  local ok, err

  if ws.path then
    wipe_placeholders(ws.path)
    ok, err = pcall(vim.cmd.tabedit, vim.fn.fnameescape(ws.path))
  else
    ok, err = pcall(vim.cmd, "tab sbuffer " .. ws.bufnr)
  end
  if not ok then
    vim.notify("jlog: " .. tostring(err), vim.log.levels.ERROR)

    return
  end
  if lnum then
    pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
  end
end

return M
