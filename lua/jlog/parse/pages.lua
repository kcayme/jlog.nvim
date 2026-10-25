local json = require("jlog.parse.json")
local utils = require("jlog.core.utils")

---@class JLogPageRange
---@field first integer first byte of the page's text, overlap included
---@field last integer last byte of the page's text, overlap included
---@field first_src integer source line (jsonl) or element ordinal (arrays) at `first`, to number entries read from it
---@field core_first_line integer|nil jsonl: source line of the page's first own entry
---@field core_last_line integer|nil jsonl: last source line of the page's own entries
---@field core_first_element integer|nil arrays: ordinal of the page's first own element
---@field core_last_element integer|nil arrays: ordinal of the page's last own element
---@field last_src integer|nil arrays: ordinal of the last element in `first..last`

---@class JLogPageIndex
---@field text string
---@field format JLogFormat
---@field size integer
---@field overlap integer
---@field snap integer most lines a boundary moves to reach a line that starts an entry
---@field from_end boolean page 1 holds the end of the text
---@field ranges JLogPageRange[] jsonl: ranges of the pages found so far, in page order
---@field starts integer[] arrays: core start elements in file order
---@field offsets table<integer, integer> arrays: start byte of the elements a range needs
---@field seps table<integer, integer> arrays: byte of the `,` or `]` after the elements a range needs
---@field scanned integer arrays: elements scanned so far
---@field total integer|nil arrays: element count, once known
---@field done boolean
---@field deadline number
---@field worker thread
local Index = {}
Index.__index = Index

local M = {}

local BYTE_NEWLINE = 10
local BYTE_QUOTE = 34
local BYTE_BACKSLASH = 92
local BYTE_OPEN_BRACKET = 91
local BYTE_CLOSE_BRACKET = 93
local BYTE_OPEN_BRACE = 123
local BYTE_CLOSE_BRACE = 125
-- units (lines or elements) scanned between deadline checks; also the least progress of a scan call
local CHECK_EVERY = 1024
-- lines tried while snapping between deadline checks: a line that is not JSON costs a failed decode
local SNAP_CHECK_EVERY = 64

local find, byte, sub = string.find, string.byte, string.sub

local skip_space = utils.skip_space

---@param text string
---@param pos integer
---@return integer
local function trim_back(text, pos)
  while pos > 0 and find(" \t\r\n", sub(text, pos, pos), 1, true) do
    pos = pos - 1
  end

  return pos
end

---@param text string
---@param pos integer
---@return integer newline the last newline at or before `pos`, 0 when there is none
local function prev_newline(text, pos)
  for at = pos, 1, -1 do
    if byte(text, at) == BYTE_NEWLINE then
      return at
    end
  end

  return 0
end

---@param text string
---@param pos integer
---@return integer newline the first newline at or after `pos`, `#text + 1` when there is none
local function next_newline(text, pos)
  return (find(text, "\n", pos, true)) or #text + 1
end

---A line starts an entry wherever it falls when it holds a JSON object, as `source.append_lines` reads it.
---@param text string
---@param first integer
---@param last integer
---@return boolean
local function is_entry(text, first, last)
  local line = sub(text, first, last):gsub("\r$", "")

  return json.object_at(line) ~= nil
end

---@param text string
---@param quote integer byte of the opening quote
---@return integer|nil closing the closing quote
local function skip_string(text, quote)
  local at, before

  repeat
    at = find(text, '"', quote + 1, true)
    if not at then
      return nil
    end
    before = at - 1
    while byte(text, before) == BYTE_BACKSLASH do
      before = before - 1
    end
    quote = at
  until (at - 1 - before) % 2 == 0

  return at
end

---@param text string
---@param pos integer first byte of an element
---@return integer sep the `,` or `]` that ends the element, `#text + 1` when the text ends first
local function element_end(text, pos)
  local depth = 0
  local at, code

  while true do
    at = find(text, '[%[%]{}",]', pos)
    if not at then
      return #text + 1
    end
    code = byte(text, at)
    if code == BYTE_QUOTE then
      at = skip_string(text, at)
      if not at then
        return #text + 1
      end
    elseif code == BYTE_OPEN_BRACKET or code == BYTE_OPEN_BRACE then
      depth = depth + 1
    elseif depth > 0 and (code == BYTE_CLOSE_BRACKET or code == BYTE_CLOSE_BRACE) then
      depth = depth - 1
    elseif depth == 0 then
      return at
    end
    pos = at + 1
  end
end

---@param index JLogPageIndex
---@param units integer units scanned so far
---@param snapped integer|nil lines tried so far while snapping
local function checkpoint(index, units, snapped)
  local due = units % CHECK_EVERY == 0 or (snapped and snapped > 0 and snapped % SNAP_CHECK_EVERY == 0)

  if due and vim.uv.hrtime() >= index.deadline then
    coroutine.yield()
  end
end

---Start byte and line of the line `overlap` lines before `pos`, moved up to `snap` lines back to an entry start.
---@param index JLogPageIndex
---@param pos integer first byte of line `line`
---@param line integer
---@return integer pos
---@return integer line
local function lead_start(index, pos, line)
  local text = index.text
  local moved = 0

  for _ = 1, index.overlap do
    if line == 1 then
      return 1, 1
    end
    pos, line = prev_newline(text, pos - 2) + 1, line - 1
  end
  while line > 1 and moved < index.snap and not is_entry(text, pos, next_newline(text, pos) - 1) do
    pos, line, moved = prev_newline(text, pos - 2) + 1, line - 1, moved + 1
    checkpoint(index, 1, moved)
  end

  return pos, line
end

---Last byte of the `overlap` lines from `pos`, moved up to `snap` lines on to the end of the entry they end in.
---@param index JLogPageIndex
---@param pos integer first byte of a line, or `#text + 1`
---@return integer last
local function trail_end(index, pos)
  local text = index.text
  local moved = 0

  for _ = 1, index.overlap do
    pos = pos <= #text and next_newline(text, pos) + 1 or pos
  end
  while pos <= #text and moved < index.snap and not is_entry(text, pos, next_newline(text, pos) - 1) do
    pos, moved = next_newline(text, pos) + 1, moved + 1
    checkpoint(index, 1, moved)
  end

  return pos > #text and #text or pos - 2
end

---Record the page whose core is lines `line..stop_line - 1`, starting at byte `pos` and stopping at `stop`.
---@param index JLogPageIndex
---@param pos integer
---@param line integer
---@param stop integer
---@param stop_line integer
---@param starts_entry boolean false when the snap limit put the core start on a continuation line
local function add_page(index, pos, line, stop, stop_line, starts_entry)
  local first, first_src = pos, line

  -- no lead then: a slice from the core start reads the cut continuation lines as this page's own entries
  if starts_entry then
    first, first_src = lead_start(index, pos, line)
  end

  index.ranges[#index.ranges + 1] = {
    first = first,
    last = trail_end(index, stop),
    first_src = first_src,
    core_first_line = line,
    core_last_line = stop_line - 1,
  }
end

---Pages from the end: every `size`-th line back, moved up to `snap` lines further back to an entry start.
---@param index JLogPageIndex
local function scan_lines_back(index)
  local text = index.text
  local last = byte(text, #text) == BYTE_NEWLINE and #text - 1 or #text
  local line, count, pos = 0, 0, 1
  local limit = index.size + index.snap
  local stop, stop_line, newline, entry

  -- absolute line numbers need the line count first
  while pos <= #text do
    pos, line = next_newline(text, pos) + 1, line + 1
    checkpoint(index, line)
  end
  stop, stop_line = #text + 1, line + 1
  while last >= 0 do
    newline = prev_newline(text, last)
    count = count + 1
    entry = count >= index.size and newline > 0 and is_entry(text, newline + 1, last)
    if entry or (count >= limit and newline > 0) then
      add_page(index, newline + 1, line, stop, stop_line, entry)
      stop, stop_line, count = newline + 1, line, 0
    end
    if newline == 0 then
      break
    end
    last, line = newline - 1, line - 1
    checkpoint(index, line, count - index.size)
  end
  add_page(index, 1, 1, stop, stop_line, true)
end

---Pages from the start: every `size`-th line on, moved up to `snap` lines further on to an entry start.
---@param index JLogPageIndex
local function scan_lines_forward(index)
  local text = index.text
  local pos, line, count = 1, 0, 0
  local start, start_line, start_entry = 1, 1, true
  local limit = index.size + index.snap
  local newline, entry

  while pos <= #text do
    newline = next_newline(text, pos)
    line = line + 1
    entry = count >= index.size and is_entry(text, pos, newline - 1)
    if entry or count >= limit then
      add_page(index, start, start_line, pos, line, start_entry)
      start, start_line, start_entry, count = pos, line, entry, 0
    end
    count = count + 1
    pos = newline + 1
    checkpoint(index, line, count - index.size)
  end
  add_page(index, start, start_line, #text + 1, line + 1, start_entry)
end

---Walk the array's elements, calling `visit(element, start, sep)` for each.
---@param index JLogPageIndex
---@param visit fun(element: integer, start: integer, sep: integer)
---@return integer count
local function walk_elements(index, visit)
  local text = index.text
  local pos = skip_space(text, 1)
  local element = 0
  local sep

  if byte(text, pos) ~= BYTE_OPEN_BRACKET then
    return 0
  end
  pos = skip_space(text, pos + 1)
  if byte(text, pos) == BYTE_CLOSE_BRACKET then
    return 0
  end
  while true do
    element = element + 1
    sep = element_end(text, pos)
    visit(element, pos, sep)
    if sep > #text or byte(text, sep) == BYTE_CLOSE_BRACKET then
      return element
    end
    pos = skip_space(text, sep + 1)
    checkpoint(index, element)
  end
end

---Element core starts on a grid from `base`, with the bytes a range needs for its overlap.
---@param index JLogPageIndex
local function scan_elements(index)
  local size, overlap = index.size, index.overlap
  local base = 1
  local total, last_sep

  if index.from_end then
    total = walk_elements(index, function() end)
    base = total + 1
  end
  total = walk_elements(index, function(element, start, sep)
    last_sep = sep
    if element == 1 or (element - base) % size == 0 then
      index.starts[#index.starts + 1] = element
      index.offsets[element] = start
    elseif (element - base + overlap) % size == 0 then
      index.offsets[element] = start
    end
    if (element - base + 1 - overlap) % size == 0 then
      index.seps[element] = sep
    end
    index.scanned = element
  end)
  index.total = total
  index.seps[total] = last_sep
  if total == 0 then
    index.starts[1] = 1
  end
end

---@param index JLogPageIndex
---@param page integer
---@return JLogPageRange
local function element_range(index, page)
  local starts, total = index.starts, index.total or index.scanned
  local slot = index.from_end and #starts - page + 1 or page
  local core_first = starts[slot] or 1
  local core_last = starts[slot + 1] and starts[slot + 1] - 1 or total
  local lead = math.max(1, core_first - index.overlap)
  local trail = math.min(total, core_last + index.overlap)

  if total == 0 then
    return { first = 1, last = 0, first_src = 1, core_first_element = 1, core_last_element = 0, last_src = 0 }
  end

  return {
    first = index.offsets[lead],
    last = trim_back(index.text, index.seps[trail] - 1),
    first_src = lead,
    last_src = trail,
    core_first_element = core_first,
    core_last_element = core_last,
  }
end

---Advance boundary finding until `deadline`, a `vim.uv.hrtime()`.
---@param deadline number
---@return boolean done
Index.scan = function(self, deadline)
  local ok, err

  if self.done then
    return true
  end
  self.deadline = deadline
  ok, err = coroutine.resume(self.worker)
  if not ok then
    error(err, 0)
  end
  self.done = coroutine.status(self.worker) == "dead"

  return self.done
end

---@return integer|nil count once the scan is done
Index.count = function(self)
  if not self.done then
    return nil
  end

  return self.format == "jsonl" and #self.ranges or #self.starts
end

---@return integer known pages whose ranges are known so far
Index.known = function(self)
  if self.format == "jsonl" then
    return #self.ranges
  end
  if self.done then
    return #self.starts
  end
  if self.from_end then
    return 0
  end

  return math.max(0, math.floor((self.scanned - math.max(1, self.overlap)) / self.size))
end

---Entries read from `first..last` numbered from `first_src` are the page's own when their `src` is in its core.
---@param page integer 1 holds the newest entries
---@return JLogPageRange|nil
Index.range = function(self, page)
  if page < 1 or page > self:known() then
    return nil
  end
  if self.format == "jsonl" then
    return self.ranges[page]
  end

  return element_range(self, page)
end

---The page whose own entries hold source position `src`, else 1.
---@param src integer|nil
---@return integer
Index.page_of = function(self, src)
  local range

  for page = 1, src and self:count() or 0 do
    range = self:range(page)
    if
      src >= (range.core_first_line or range.core_first_element)
      and src <= (range.core_last_line or range.core_last_element)
    then
      return page
    end
  end

  return 1
end

---A page index over `text`, built by `scan` in steps.
---@param text string
---@param format JLogFormat
---@param opts JLogPagingOptions
---@param from_end boolean page 1 holds the end of the text: true for jsonl shown newest first
---@return JLogPageIndex
M.new = function(text, format, opts, from_end)
  local index = setmetatable({
    text = text,
    format = format,
    size = opts.size,
    overlap = opts.overlap,
    -- a long run of plain lines splits rather than make one huge page
    snap = math.max(1, math.floor(opts.size / 10)),
    from_end = from_end,
    ranges = {},
    starts = {},
    offsets = {},
    seps = {},
    scanned = 0,
    done = false,
    deadline = 0,
  }, Index)

  index.worker = coroutine.create(function()
    if format ~= "jsonl" then
      scan_elements(index)
    elseif from_end then
      scan_lines_back(index)
    else
      scan_lines_forward(index)
    end
  end)

  return index
end

M.element_end = element_end

return M
