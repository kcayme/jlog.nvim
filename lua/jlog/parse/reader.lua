local parallel = require("jlog.parse.parallel")
local source = require("jlog.parse.source")

local M = {}

-- lines or array elements read per call when the caller gives no count
M.chunk_size = 500

---Reads `count` more units (default `chunk_size`) into `entries`; returns the fraction read (nil when done)
---and true while waiting on workers.
---@alias JLogReader fun(entries: JLogEntry[], on_json: function|nil, count: integer|nil,
---on_fields: fun(fields: table)|nil): number|nil, boolean|nil

---@param text string
---@param pos integer byte position of the next unparsed line
---@param lnum integer source line number of that line
---@param stop integer last byte to read
---@return JLogReader
local function line_reader(text, pos, lnum, stop)
  local start = pos

  return function(entries, on_json, count)
    local lines

    lines, pos = source.take_lines(text, pos, count or M.chunk_size, stop)
    source.append_lines(entries, lines, lnum, on_json)
    lnum = lnum + #lines

    return pos <= stop and (pos - start) / (stop - start + 1) or nil
  end
end

---A broken array keeps what was read; the unparsed rest follows as plain entries, one per line.
---@param entries JLogEntry[] mutated
---@param text string
---@param rest_at integer where the unparsed rest starts
---@param stop integer last byte of the rest
---@param err string
local function keep_broken_rest(entries, text, rest_at, stop, err)
  vim.notify("jlog: broken JSON array: " .. err .. "; the rest is shown as plain lines", vim.log.levels.WARN)
  source.append_plain(entries, text:sub(rest_at, stop))
end

---@param text string
---@param pos integer|nil where `source.read_elements` goes on; nil when nothing is left
---@param format JLogFormat
---@param first_src integer ordinal of the element at `pos`
---@param last_src integer|nil ordinal of the last element to read; nil reads to the end of the array
---@param stop integer last byte to read
---@return JLogReader
local function element_reader(text, pos, format, first_src, last_src, stop)
  local start = pos

  return function(entries, on_json, count)
    local wanted = math.min(count or M.chunk_size, (last_src or math.huge) - first_src + 1 - #entries)
    local chunk, next_pos, err

    if not pos or wanted <= 0 or (#entries == 0 and not text:find("%S")) then
      return nil
    end
    chunk, next_pos, err = source.read_elements(text, pos, wanted, format, first_src + #entries, on_json)
    vim.list_extend(entries, chunk)
    pos = not err and next_pos or nil
    if err then
      keep_broken_rest(entries, text, next_pos, stop, err)

      return nil
    end

    return pos and (pos - start) / (stop - start + 1) or nil
  end
end

---Stable merge sort of `list` in place; `checkpoint` is called every few thousand moves and may yield.
---@param list JLogEntry[]
---@param less fun(left: JLogEntry, right: JLogEntry): boolean
---@param checkpoint fun()
local function merge_sort(list, less, checkpoint)
  local count = #list
  local from, to = list, {}
  local width = 1
  local middle, last, left, right

  while width < count do
    for start = 1, count, 2 * width do
      middle = math.min(start + width, count + 1)
      last = math.min(start + 2 * width, count + 1)
      left, right = start, middle
      for slot = start, last - 1 do
        if left < middle and (right >= last or not less(from[right], from[left])) then
          to[slot] = from[left]
          left = left + 1
        else
          to[slot] = from[right]
          right = right + 1
        end
        if slot % 4096 == 0 then
          checkpoint()
        end
      end
    end
    from, to = to, from
    width = width * 2
  end
  if from ~= list then
    for slot = 1, count do
      list[slot] = from[slot]
    end
  end
end

---Wrap a loki reader: once everything is read, sort by timestamp, a tick's budget at a time.
---@param read JLogReader
---@param tick_ns number sort work per call
---@return JLogReader
local function sorting_reader(read, tick_ns)
  local sorter, deadline
  local function checkpoint()
    if vim.uv.hrtime() >= deadline then
      coroutine.yield()
    end
  end

  return function(entries, on_json, count)
    local fraction

    -- read again after the end, as a load started after a first read that finished everything does
    if sorter and coroutine.status(sorter) == "dead" then
      return nil
    end
    if not sorter then
      fraction = read(entries, on_json, count)
      if fraction then
        return fraction
      end
      sorter = coroutine.create(function()
        merge_sort(entries, source.older_first, checkpoint)
      end)
    end
    deadline = vim.uv.hrtime() + tick_ns
    assert(coroutine.resume(sorter))

    return coroutine.status(sorter) ~= "dead" and 1 or nil
  end
end

---@param text string
---@param pos integer
---@return integer start first byte of the line holding `pos`
local function line_start(text, pos)
  while pos > 1 and text:byte(pos - 1) ~= 10 do
    pos = pos - 1
  end

  return pos
end

---The reader for an array file; an unordered loki export is sorted once read, everything else keeps file order.
---@param text string
---@param format JLogFormat
---@param order "asc"|"desc"|"none"
---@param tick_ns number the loki sort's work per call
---@return JLogReader
M.source = function(text, format, order, tick_ns)
  local read

  if format == "jsonl" then
    return (#text >= parallel.min_bytes and parallel.line_reader or line_reader)(text, 1, 1, #text)
  end
  read = element_reader(text, 1, format, 1, nil, #text)

  return (format == "loki" and order == "none") and sorting_reader(read, tick_ns) or read
end

---A reader of the last `count` lines of a jsonl page that ends the file: the top of a newest-first view.
---@param text string
---@param range JLogPageRange
---@param count integer
---@return JLogReader
M.tail = function(text, range, count)
  local lnum = range.core_last_line
  local target = math.max(range.first_src, lnum - count + 1)
  local start = line_start(text, text:byte(range.last) == 10 and range.last - 1 or range.last)

  while lnum > target do
    start, lnum = line_start(text, start - 1), lnum - 1
  end

  return line_reader(text, start, lnum, range.last)
end

---@param text string
---@param format JLogFormat
---@param range JLogPageRange
---@return JLogReader
M.page = function(text, format, range)
  if format == "jsonl" then
    return (range.last - range.first + 1 >= parallel.min_bytes and parallel.line_reader or line_reader)(
      text,
      range.first,
      range.first_src,
      range.last
    )
  end

  -- the first element is read from the array's `[`
  return element_reader(
    text,
    range.first_src == 1 and 1 or range.first,
    format,
    range.first_src,
    range.last_src,
    range.last
  )
end

return M
