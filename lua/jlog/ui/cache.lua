-- The view mode not shown, kept in a hidden buffer so switching back to it needs no render.
local M = {}

---A view's buffer and the state tied to its lines; a mode switch exchanges these with the cached buffer's.
---@class JLogViewBuffer
---@field bufnr integer
---@field items JLogItem[]
---@field line_item integer[]
---@field item_line integer[]
---@field entry_item table<integer, integer>
---@field first_header integer|nil
---@field rendered_entries JLogEntry[]|nil
---@field redraw_spans table<integer, JLogSpan[][]>
---@field complete boolean
---@field edited boolean
---@field mode JLogViewMode|nil
---@field folded table<integer, boolean>
---@field pending table<integer, boolean>

-- the fields of a `JLogViewBuffer`, exchanged between a view and its cache
local BUFFER_FIELDS = {
  "bufnr",
  "items",
  "line_item",
  "item_line",
  "entry_item",
  "first_header",
  "rendered_entries",
  "redraw_spans",
  "complete",
  "edited",
  "mode",
  "folded",
  "pending",
}

---State for `bufnr`, a buffer nothing has been rendered into yet.
---@param bufnr integer
---@return JLogViewBuffer
M.empty = function(bufnr)
  return {
    bufnr = bufnr,
    items = {},
    line_item = {},
    item_line = {},
    entry_item = {},
    redraw_spans = {},
    complete = false,
    edited = false,
    folded = {},
    pending = {},
  }
end

---@param bufnr integer
M.wipe = function(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

---Wipe the view's cached buffer, if any.
---@param view JLogView
M.drop = function(view)
  local cached = view.cache

  view.cache = nil
  if cached then
    M.wipe(cached.bufnr)
  end
end

---The cached buffer still shows `items` of `entries` in `mode`.
---@param cached JLogViewBuffer
---@param mode JLogViewMode
---@param items JLogItem[]
---@param entries JLogEntry[]
---@return boolean
M.matches = function(cached, mode, items, entries)
  return cached.mode == mode and cached.items == items and cached.rendered_entries == entries
end

---Exchange the view's buffer and its state with `other`'s, showing `other`'s buffer in the view's windows.
---@param view JLogView
---@param other JLogViewBuffer
---@return JLogViewBuffer left the buffer that was shown, now hidden
M.swap = function(view, other)
  local left = {}
  local windows = vim.fn.win_findbuf(view.bufnr)

  for _, field in ipairs(BUFFER_FIELDS) do
    left[field], view[field] = view[field], other[field]
  end
  -- a render still writing the buffer being left stops
  view.generation = view.generation + 1
  view.stream, view.placeholders = nil, false
  vim.bo[left.bufnr].bufhidden = "hide"
  vim.bo[view.bufnr].bufhidden = "wipe"
  for _, winid in ipairs(windows) do
    vim.api.nvim_win_call(winid, function()
      vim.api.nvim_win_set_buf(winid, view.bufnr)
    end)
  end

  return left
end

---Keep `left` as the view's cache when its render finished untouched, else wipe it.
---@param view JLogView
---@param left JLogViewBuffer
M.keep_or_wipe = function(view, left)
  if left.complete and not left.edited then
    view.cache = left
  else
    M.wipe(left.bufnr)
  end
end

return M
