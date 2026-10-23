local M = {}

---@alias JLogKeymapScope "view"|"sidebar"|"raw"
---@alias JLogKeymapHandler fun(ws: table, bufnr: integer)

---Off a facet row, the sidebar keys keep their built-in meaning (`<CR>` moves down, `g` starts `gg`).
---@param ws table workspace
---@param action string
local function feed_default(ws, action)
  vim.api.nvim_feedkeys(vim.keycode(ws.opts.keymaps[action]), "n", false)
end

-- Workspace methods (`close`, `focus_sidebar`, ...) are looked up on keypress, so `ws` may be a plain table here.
---@type table<JLogKeymapScope, table<string, JLogKeymapHandler>>
local SCOPES = {
  view = {
    toggle_entry = function(ws)
      ws.view:toggle_entry()
    end,
    toggle_mode = function(ws)
      ws.view:toggle_mode()
    end,
    raw = function(ws)
      ws.view:show_raw()
    end,
    reverse = function(ws)
      ws:toggle_reverse()
    end,
    next_entry = function(ws)
      ws.view:move("entry", 1)
    end,
    prev_entry = function(ws)
      ws.view:move("entry", -1)
    end,
    next_error = function(ws)
      ws.view:move("error", 1)
    end,
    prev_error = function(ws)
      ws.view:move("error", -1)
    end,
    next_page = function(ws)
      if ws.page then
        ws:goto_page(ws.page + 1)
      end
    end,
    prev_page = function(ws)
      if ws.page then
        ws:goto_page(ws.page - 1)
      end
    end,
    focus_sidebar = function(ws)
      ws:focus_sidebar()
    end,
    toggle_sidebar = function(ws)
      ws:toggle_sidebar()
    end,
    close = function(ws)
      ws:close()
    end,
  },
  sidebar = {
    close = function(ws)
      ws:close()
    end,
    add_filter = function(ws)
      if not ws.sidebar:activate() then
        feed_default(ws, "add_filter")
      end
    end,
    group_by = function(ws)
      if not ws.sidebar:group_at_cursor() then
        feed_default(ws, "group_by")
      end
    end,
  },
  raw = {
    -- only line-based sources have a source line to jump to
    raw = function(ws, bufnr)
      if ws.format ~= "jsonl" then
        return
      end
      ws:open_raw(vim.b[bufnr].jlog_src)
    end,
    close = function()
      vim.api.nvim_win_close(0, true)
    end,
  },
}

---Map every action of `scope` whose `opts.keymaps` key is set, buffer-locally.
---@param bufnr integer
---@param scope JLogKeymapScope
---@param ws table workspace
M.attach = function(bufnr, scope, ws)
  local lhs

  for action, handler in pairs(SCOPES[scope]) do
    lhs = ws.opts.keymaps[action]
    if lhs then
      vim.keymap.set("n", lhs, function()
        handler(ws, bufnr)
      end, { buffer = bufnr, nowait = true, silent = true, desc = "jlog: " .. action })
    end
  end
end

return M
