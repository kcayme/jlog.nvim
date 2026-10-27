-- Helpers shared across modules: centered floats and the tick budget.
local M = {}

-- the event loop pass the shared tick deadline belongs to, by its cached loop time, and that deadline
local pass_time, pass_deadline

---Where a background job's tick stops: jobs run in one event loop pass share the first one's budget.
---@param tick_ns number the job's own budget; 0 does one unit of work per tick
---@return number deadline `vim.uv.hrtime()` to stop at
M.tick_deadline = function(tick_ns)
  local now = vim.uv.hrtime()

  -- `vim.uv.now()` is cached per loop pass, so it is the same for every timer callback in it
  if vim.uv.now() ~= pass_time then
    pass_time, pass_deadline = vim.uv.now(), now + tick_ns
  end

  return math.min(pass_deadline, now + tick_ns)
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
