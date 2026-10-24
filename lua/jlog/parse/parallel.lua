local source = require("jlog.parse.source")
local workers = require("jlog.workers")

---@class JLogChunk
---@field first integer first byte
---@field last integer last byte of its last line, newline excluded
---@field next_pos integer first byte after it
---@field done boolean|nil its job has reported
---@field err string|nil
---@field result string|nil the job's mpack result, until decoded
---@field positions integer[]|nil decoded JSON position of each line
---@field fields table|nil decoded field counts
---@field next_line integer|nil index of the next line to append

local M = {}

-- lines appended per call, from a finished chunk or parsed on the main thread after a fallback
local LINES_PER_CALL = 500

-- about this many bytes go to one worker job, cut at a newline
M.chunk_bytes = 4 * 1024 * 1024
-- a range smaller than this loads on the main thread
M.min_bytes = 1024 * 1024

---The chunk starting at `pos`: about `chunk_bytes`, ending at a newline or at the end of `text`.
---@param text string
---@param pos integer
---@param stop integer
---@return JLogChunk
local function cut_chunk(text, pos, stop)
  local newline = text:find("\n", math.min(pos + M.chunk_bytes - 1, stop), true)

  if not newline then
    return { first = pos, last = #text, next_pos = #text + 1 }
  end

  return { first = pos, last = newline - 1, next_pos = newline + 1 }
end

---@param text string
---@param chunk JLogChunk
---@param progress { at: integer } its `at` set to `vim.uv.now()` when the job reports
local function dispatch(text, chunk, progress)
  -- the callback holds only the chunk and progress, so a dropped load keeps neither the text nor its entries alive
  workers.run("parse_lines", vim.mpack.encode({ text = text:sub(chunk.first, chunk.last) }), function(err, result)
    chunk.done, chunk.err, chunk.result = true, err, result
    progress.at = vim.uv.now()
  end)
end

---Append up to `max_lines` lines of a chunk from `pos`, as `source.append_lines` would, using the job's positions.
---@param entries JLogEntry[] mutated
---@param text string
---@param chunk JLogChunk its `positions` decoded; `next_line` is the index of the line at `pos`
---@param pos integer
---@param lnum integer source line number of the line at `pos`
---@param max_lines integer
---@return integer next_pos
---@return integer appended lines consumed, blank and continuation lines included
local function append_slice(entries, text, chunk, pos, lnum, max_lines)
  local positions = chunk.positions
  local first_line = chunk.next_line
  local last_line = math.min(#positions, first_line + max_lines - 1)
  local total = #positions
  local line_end, line, last, json_at, count

  count = #entries
  for index = first_line, last_line do
    line_end = index < total and text:find("\n", pos, true) - 1 or chunk.last
    line = text:sub(pos, line_end)
    pos = line_end + 2
    json_at = positions[index]
    if text:byte(line_end) == 13 then
      line = line:sub(1, -2)
    end
    if json_at ~= 0 then
      count = count + 1
      entries[count] = { src = lnum + index - first_line, raw = line, body = line, json_at = json_at }
    elseif line:find("%S") then
      last = entries[count]
      if last and last.json_at then
        last.cont = last.cont or {}
        last.cont[#last.cont + 1] = line
      else
        count = count + 1
        entries[count] = { src = lnum + index - first_line, raw = line, body = line }
      end
    end
  end
  chunk.next_line = last_line + 1

  return pos, last_line - first_line + 1
end

---A `JLogReader` of the jsonl lines from `pos` to `stop` that parses them on worker threads.
---@param text string
---@param pos integer byte position of the next unparsed line
---@param lnum integer source line number of that line
---@param stop integer last byte to read
---@return JLogReader
M.line_reader = function(text, pos, lnum, stop)
  local start = pos
  -- dispatched and not yet fully appended, in source order
  local chunks = {}
  local cut = pos
  local fallback = false
  -- when it last dispatched, received or appended
  local progress = { at = vim.uv.now() }

  local function fraction()
    return pos <= stop and (pos - start) / (stop - start + 1) or nil
  end

  ---Give up on workers when waiting for them has made no progress for `workers.stall_ms`.
  ---@return boolean stalled
  local function stalled()
    if vim.uv.now() - progress.at <= workers.stall_ms then
      return false
    end
    -- the chunks still out are dropped, so their late results are never read; their lines are parsed here
    fallback, chunks, cut = true, {}, pos

    return true
  end

  return function(entries, on_json, count, on_fields)
    local lines, chunk, decoded, appended, gave_up

    -- chunks already out still report, as a result or an error
    fallback = fallback or (not chunks[1] and not workers.available())
    if fallback or (count and not chunks[1]) then
      lines, pos = source.take_lines(text, pos, count or LINES_PER_CALL, stop)
      source.append_lines(entries, lines, lnum, on_json)
      lnum, cut = lnum + #lines, pos

      return fraction()
    end

    -- the shared cap also counts jobs of a dropped load that are still running
    while cut <= stop and #chunks < workers.limit() and workers.in_flight() < workers.limit() and workers.available() do
      chunk = cut_chunk(text, cut, stop)
      cut = chunk.next_pos
      chunks[#chunks + 1] = chunk
      dispatch(text, chunk, progress)
      progress.at = vim.uv.now()
    end
    chunk = chunks[1]
    if not chunk and cut > stop then
      return fraction()
    end
    -- no chunk out means the cap is full of other jobs; either way this call waits on workers
    if not chunk or not chunk.done then
      gave_up = stalled()

      return fraction(), not gave_up or nil
    end
    if chunk.err then
      -- the chunks still out are dropped; their lines are parsed here from `pos` on
      fallback, chunks, cut = true, {}, pos

      return fraction()
    end

    if not chunk.positions then
      decoded = vim.mpack.decode(chunk.result)
      chunk.positions, chunk.fields, chunk.next_line, chunk.result = decoded.positions, decoded.fields, 1, nil
    end
    -- a slice per call, so the caller checks its tick budget between slices of a chunk
    pos, appended = append_slice(entries, text, chunk, pos, lnum, LINES_PER_CALL)
    lnum = lnum + appended
    progress.at = vim.uv.now()
    if chunk.next_line > #chunk.positions then
      table.remove(chunks, 1)
      pos = chunk.next_pos
      if on_fields then
        on_fields(chunk.fields)
      end
    end

    return fraction()
  end
end

return M
