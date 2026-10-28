-- Buffer-local keymaps from config.keymaps, and the help float.
local utils = require("jlog.core.utils")

local M = {}

---@alias JLogKeymapScope "view"|"sidebar"|"raw"
---@alias JLogKeymapHandler fun(ws: table, bufnr: integer)

---Rows of the key guide: the actions whose keys are shown (or a fixed key) and what they do.
---@type {title: string, rows: {actions: string[]|nil, key: string|nil, text: string}[]}[]
local HELP = {
  {
    title = "Log view",
    rows = {
      { actions = { "toggle_entry" }, text = "expand/collapse the entry" },
      { actions = { "toggle_mode" }, text = "compact/expanded view" },
      { actions = { "raw" }, text = "raw text; in it, jump to the source line" },
      { actions = { "reverse" }, text = "reverse the order" },
      { actions = { "clear" }, text = "clear filters, group and limits" },
      { actions = { "next_entry", "prev_entry" }, text = "next/previous entry" },
      { actions = { "next_error", "prev_error" }, text = "next/previous error" },
      { actions = { "next_page", "prev_page" }, text = "next/previous page" },
      { actions = { "next_match_page", "prev_match_page" }, text = "next/previous page with filter matches" },
      { actions = { "toggle_scope" }, text = "filter matches of every page in one view / back to a page" },
      { actions = { "focus_sidebar" }, text = "focus the sidebar" },
      { actions = { "toggle_sidebar" }, text = "show/hide the sidebar" },
      { actions = { "close" }, text = "close" },
    },
  },
  {
    title = "Sidebar",
    rows = {
      { key = ":w", text = "apply FILTERS, GROUP BY and LIMIT" },
      { actions = { "add_filter" }, text = "on a value: add/remove it (OR within a field)" },
      { actions = { "toggle_sidebar" }, text = "hide the sidebar" },
      { actions = { "group_by" }, text = "on a field: group by it" },
      { actions = { "ignore_field" }, text = "on a field: hide/show it in compact lines" },
      { actions = { "reverse" }, text = "reverse the order" },
      { actions = { "clear" }, text = "clear filters, group and limits" },
      { actions = { "help" }, text = "this guide" },
      { actions = { "close" }, text = "close" },
    },
  },
  {
    title = "Filter syntax",
    rows = {
      { key = "field=value", text = "equal; != not equal" },
      { key = "field>n", text = "number or time comparison; also >=, <, <=" },
      { key = "field~regex", text = "Vim regex on the field's value" },
      { key = "value", text = "Vim regex on the whole entry" },
      { key = "-term", text = "negate a term" },
      { key = "a b", text = "both match; same as a AND b" },
      { key = "a OR b", text = "either matches; AND binds tighter" },
      { key = 'msg="a b"', text = "quote spaces and the words AND/OR" },
      { key = "OR line", text = "a line starting with OR joins the one above" },
      { key = "AND line", text = "any other line must also match" },
    },
  },
}

---The guide's lines, with the keys as configured; rows whose keys are all disabled are left out.
---@param keys JLogKeymapsOptions
---@return string[]
local function help_lines(keys)
  local lines = {}
  local rows, width

  for index, section in ipairs(HELP) do
    if index > 1 then
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = section.title
    rows, width = {}, 8
    for _, row in ipairs(section.rows) do
      rows[#rows + 1] = {
        key = row.key or table.concat(
          vim.tbl_filter(
            function(lhs)
              return lhs ~= false
            end,
            vim.tbl_map(function(action)
              return keys[action]
            end, row.actions)
          ),
          " "
        ),
        text = row.text,
      }
      width = math.max(width, #rows[#rows].key)
    end
    -- keys are padded to the section's longest, so the filter syntax lines up without widening the key sections
    for _, row in ipairs(rows) do
      if row.key ~= "" then
        lines[#lines + 1] = string.format("  %-" .. width .. "s %s", row.key, row.text)
      end
    end
  end

  return lines
end

---Open the key guide in a centered float; `q`, `<Esc>` or the help key closes it.
---@param ws table workspace
local function show_help(ws)
  local bufnr, winid = utils.open_float(help_lines(ws.opts.keymaps), "jlog keys")

  for _, lhs in ipairs({ "q", "<Esc>", ws.opts.keymaps.help }) do
    if lhs then
      vim.keymap.set("n", lhs, function()
        pcall(vim.api.nvim_win_close, winid, true)
      end, { buffer = bufnr, nowait = true, silent = true })
    end
  end
end

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
    clear = function(ws)
      ws:clear_all()
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
    -- from a page still loading, so a second press goes one further; from all pages, the cursor entry's page
    next_page = function(ws)
      ws:step_page(1)
    end,
    prev_page = function(ws)
      ws:step_page(-1)
    end,
    toggle_scope = function(ws)
      ws:toggle_scope()
    end,
    next_match_page = function(ws)
      ws:goto_match_page(1)
    end,
    prev_match_page = function(ws)
      ws:goto_match_page(-1)
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
    reverse = function(ws)
      ws:toggle_reverse()
    end,
    clear = function(ws)
      ws:clear_all()
    end,
    toggle_sidebar = function(ws)
      ws:toggle_sidebar()
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
    ignore_field = function(ws)
      if not ws.sidebar:ignore_at_cursor() then
        feed_default(ws, "ignore_field")
      end
    end,
    help = function(ws)
      show_help(ws)
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
