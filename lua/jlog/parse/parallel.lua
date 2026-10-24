local facets = require("jlog.query.facets")
local source = require("jlog.parse.source")
local workers = require("jlog.workers")

---@class JLogChunk
---@field first integer first byte
---@field last integer last byte of its last line, newline excluded
---@field next_pos integer first byte after it
---@field done boolean|nil its job has reported
---@field err string|nil
---@field result string|nil the job's mpack result

local M = {}

-- lines parsed per call once a load falls back to the main thread
local FALLBACK_LINES = 500

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
local function dispatch(text, chunk)
  -- the callback holds only the chunk, so a dropped load keeps neither the text nor its entries alive
  workers.run("parse_lines", vim.mpack.encode({ text = text:sub(chunk.first, chunk.last) }), function(err, result)
    chunk.done, chunk.err, chunk.result = true, err, result
  end)
end

---Append a chunk's lines as `source.append_lines` would, with each line's JSON position from its job.
---@param entries JLogEntry[] mutated
---@param text string
---@param chunk JLogChunk
---@param positions integer[] one per line, 0 for a line that is not JSON
---@param first_lnum integer
local function append_positions(entries, text, chunk, positions, first_lnum)
  local pos = chunk.first
  local line_end, line, last, json_at

  for index, position in ipairs(positions) do
    line_end = index < #positions and text:find("\n", pos, true) - 1 or chunk.last
    line = text:sub(pos, line_end):gsub("\r$", "")
    pos = line_end + 2
    if line:find("%S") then
      last = entries[#entries]
      json_at = position ~= 0 and position or nil
      if not json_at and last and last.json_at then
        last.cont = last.cont or {}
        last.cont[#last.cont + 1] = line
      else
        entries[#entries + 1] = { src = first_lnum + index - 1, raw = line, body = line, json_at = json_at }
      end
    end
  end
end

---A `JLogReader` of the jsonl lines from `pos` to `stop` that parses them on worker threads.
---@param text string
---@param pos integer byte position of the next unparsed line
---@param lnum integer source line number of that line
---@param stop integer last byte to read
---@return JLogReader
M.line_reader = function(text, pos, lnum, stop)
  local start = pos
  -- dispatched and not yet appended, in source order
  local chunks = {}
  local cut = pos
  local fallback = false

  local function fraction()
    return pos <= stop and (pos - start) / (stop - start + 1) or nil
  end

  return function(entries, on_json, count, counter)
    local lines, chunk, decoded

    fallback = fallback or not workers.available()
    if fallback or (count and not chunks[1]) then
      lines, pos = source.take_lines(text, pos, count or FALLBACK_LINES, stop)
      source.append_lines(entries, lines, lnum, on_json)
      lnum, cut = lnum + #lines, pos

      return fraction()
    end

    while #chunks < workers.limit() and cut <= stop do
      chunk = cut_chunk(text, cut, stop)
      cut = chunk.next_pos
      chunks[#chunks + 1] = chunk
      dispatch(text, chunk)
    end
    chunk = chunks[1]
    if not chunk then
      return fraction()
    end
    if not chunk.done then
      return fraction(), true
    end
    if chunk.err then
      -- the chunks still out are dropped; their lines are parsed here from `pos` on
      fallback, chunks, cut = true, {}, pos

      return fraction()
    end

    table.remove(chunks, 1)
    decoded = vim.mpack.decode(chunk.result)
    append_positions(entries, text, chunk, decoded.positions, lnum)
    lnum, pos = lnum + #decoded.positions, chunk.next_pos
    if counter then
      facets.merge(counter, decoded.fields)
    end

    return fraction()
  end
end

return M
