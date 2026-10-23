local json = require("jlog.parse.json")

---@class JLogPageRange
---@field first integer first byte of the page's text, overlap included
---@field last integer last byte of the page's text, overlap included
---@field core_first integer ordinal, among the entries read from `first..last`, of the page's first own entry
---@field core_last integer ordinal of the page's last own entry

---@class JLogPageIndex
---@field text string
---@field format JLogFormat
---@field size integer
---@field overlap integer
---@field from_end boolean page 1 holds the end of the text
---@field starts integer[] jsonl: core start bytes in page order; arrays: core start elements in file order
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

local find, byte, sub = string.find, string.byte, string.sub

---@param text string
---@param pos integer
---@return integer
local function skip_space(text, pos)
  return (find(text, "[^ \t\r\n]", pos)) or #text + 1
end

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

---@param text string
---@param first integer
---@param last integer
---@return boolean blank
---@return boolean json
local function classify(text, first, last)
  local line = sub(text, first, last):gsub("\r$", "")

  return not find(line, "%S"), json.object_at(line) ~= nil
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
local function checkpoint(index, units)
  -- an array paged from its end knows no page before the scan ends, so it need not wait for one
  local waits = index:known() < 1 and (index.format == "jsonl" or not index.from_end)

  if units % CHECK_EVERY == 0 and not waits and vim.uv.hrtime() >= index.deadline then
    coroutine.yield()
  end
end

---Core starts from the end: every `size`-th line back, moved further back to a line that starts an entry.
---@param index JLogPageIndex
local function scan_lines_back(index)
  local text = index.text
  local last = byte(text, #text) == BYTE_NEWLINE and #text - 1 or #text
  local count, units = 0, 0
  local newline, blank, is_json

  while last >= 0 do
    newline = prev_newline(text, last)
    count, units = count + 1, units + 1
    if count >= index.size and newline > 0 then
      blank, is_json = classify(text, newline + 1, last)
      if not blank and is_json then
        index.starts[#index.starts + 1] = newline + 1
        count = 0
      end
    end
    if newline == 0 then
      break
    end
    last = newline - 1
    checkpoint(index, units)
  end
  index.starts[#index.starts + 1] = 1
end

---Core starts from the start: every `size`-th line on, moved further on to a line that starts an entry.
---@param index JLogPageIndex
local function scan_lines_forward(index)
  local text = index.text
  local pos, count, units = 1, 0, 0
  local newline, blank, is_json

  index.starts[1] = 1
  while pos <= #text do
    newline = next_newline(text, pos)
    if count >= index.size then
      blank, is_json = classify(text, pos, newline - 1)
      if not blank and is_json then
        index.starts[#index.starts + 1] = pos
        count = 0
      end
    end
    count, units = count + 1, units + 1
    pos = newline + 1
    checkpoint(index, units)
  end
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
---@return integer first core's first byte
---@return integer stop byte after the core
local function line_core(index, page)
  local starts = index.starts

  if index.from_end then
    return starts[page], page == 1 and #index.text + 1 or starts[page - 1]
  end

  return starts[page], starts[page + 1] or #index.text + 1
end

---Entries in lines `first..stop - 1` read on their own, by the rule `source.append_lines` follows.
---@param text string
---@param first integer
---@param stop integer
---@return integer
local function count_entries(text, first, stop)
  local count, last_json = 0, false
  local newline, blank, is_json

  while first < stop do
    newline = math.min(next_newline(text, first), stop)
    blank, is_json = classify(text, first, newline - 1)
    if not blank and (is_json or not last_json) then
      count, last_json = count + 1, is_json
    end
    first = newline + 1
  end

  return count
end

---@param index JLogPageIndex
---@param page integer
---@return JLogPageRange
local function line_range(index, page)
  local text, overlap = index.text, index.overlap
  local core_start, core_stop = line_core(index, page)
  local first, last = core_start, #text
  local found = 0
  local line_end, newline, pos, blank, is_json, lead

  line_end = core_start - 2
  while overlap > 0 and line_end >= 0 do
    newline = prev_newline(text, line_end)
    blank, is_json = classify(text, newline + 1, line_end)
    if not blank and is_json then
      found, first = found + 1, newline + 1
    end
    if found == overlap then
      break
    end
    if newline == 0 then
      first = 1
      break
    end
    line_end = newline - 1
  end

  found, pos = 0, core_stop
  while pos <= #text do
    newline = next_newline(text, pos)
    blank, is_json = classify(text, pos, newline - 1)
    if not blank and is_json then
      found = found + 1
      if found > overlap then
        last = pos - 2
        break
      end
    end
    pos = newline + 1
  end

  -- the core starts on a JSON line or at the file start, so it counts the same read on its own
  lead = count_entries(text, first, core_start)

  return {
    first = first,
    last = last,
    core_first = lead + 1,
    core_last = lead + count_entries(text, core_start, core_stop),
  }
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
    return { first = 1, last = 0, core_first = 1, core_last = 0 }
  end

  return {
    first = index.offsets[lead],
    last = trim_back(index.text, index.seps[trail] - 1),
    core_first = core_first - lead + 1,
    core_last = core_last - lead + 1,
  }
end

---Advance boundary finding until `deadline`, a `vim.uv.hrtime()`; the first call always finds page 1.
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
  return self.done and #self.starts or nil
end

---@return integer known pages whose ranges are known so far
Index.known = function(self)
  if self.done then
    return #self.starts
  end
  if self.format == "jsonl" then
    return self.from_end and #self.starts or #self.starts - 1
  end
  if self.from_end then
    return 0
  end

  return math.max(0, math.floor((self.scanned - math.max(1, self.overlap)) / self.size))
end

---@param page integer 1 holds the newest entries
---@return JLogPageRange|nil
Index.range = function(self, page)
  if page < 1 or page > self:known() then
    return nil
  end
  if self.format == "jsonl" then
    return line_range(self, page)
  end

  return element_range(self, page)
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
    from_end = from_end,
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

return M
