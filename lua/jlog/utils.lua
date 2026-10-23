local M = {}

---@param text string
---@param pos integer
---@return integer pos first non-whitespace byte at or after `pos`
M.skip_space = function(text, pos)
  return (text:find("[^ \t\r\n]", pos)) or #text + 1
end

---Show `lines` in a read-only float centered in the editor and sized to them; its buffer is wiped on close.
---@param lines string[]
---@param title string
---@return integer bufnr
---@return integer winid
M.open_float = function(lines, title)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local width = 1
  local height = math.min(#lines, vim.o.lines - 4)
  local winid

  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width, vim.o.columns - 4)

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].modifiable = false
  winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
  })

  return bufnr, winid
end

return M
