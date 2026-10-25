local entry_model = require("jlog.parse.entry")
local json = require("jlog.parse.json")

local M = {}

-- spans are flat lists (src, first byte, last byte per entry), which decode far faster than a table per entry

---@class JLogChunkMatch
---@field lead integer[] matching lines before the first JSON line, as plain entries; the caller may join them up
---@field lead_last integer absolute byte where those lines end, 0 when there are none
---@field spans integer[] spans of matching entries from the first JSON line on
---@field last_json_src integer|nil source line of the chunk's last JSON line
---@field lines integer lines in the chunk, blank ones included; an empty chunk is one blank line

---The entries of a JSONL chunk that `pred` accepts, as `source.append_lines` builds them.
---@param text string the chunk, lines joined by "\n"
---@param first_src integer source line of its first line
---@param first_byte integer absolute byte of its first line
---@param pred fun(ctx: JLogMatchCtx): boolean
---@param opts JLogOptions
---@return JLogChunkMatch
M.match = function(text, first_src, first_byte, pred, opts)
  local src, pos = first_src, first_byte
  local lead, spans = {}, {}
  local lead_last = 0
  local index = 1
  -- where the last matching entry's end byte is in `spans`, while its continuation lines may follow
  local open
  local line, line_end, newline, json_at, decoded, entry, last_json_src, count
  local ctx = {}

  -- simple top-level values are read from the text, the rest from the line's decode
  ctx.get = function(path)
    local value, found = entry_model.peek(entry, path, opts)

    if found then
      return value
    end

    return entry_model.get(entry, decoded, path, opts)
  end

  while index <= #text do
    newline = text:find("\n", index, true) or #text + 1
    line = text:sub(index, newline - 1):gsub("\r$", "")
    line_end = pos + (newline - 1 - index)
    if line:find("%S") then
      json_at, decoded = json.object_at(line)
      entry = { raw = line, body = line, json_at = json_at }
      ctx.raw = line
      if json_at then
        last_json_src, open = src, nil
        if pred(ctx) then
          count = #spans
          spans[count + 1], spans[count + 2], spans[count + 3] = src, pos, line_end
          open = count + 3
        end
      elseif open then
        spans[open] = line_end
      elseif not last_json_src then
        lead_last = line_end
        if pred(ctx) then
          count = #lead
          lead[count + 1], lead[count + 2], lead[count + 3] = src, pos, line_end
        end
      end
    end
    pos = pos + (newline - index) + 1
    index = newline + 1
    src = src + 1
  end

  return {
    lead = lead,
    lead_last = lead_last,
    spans = spans,
    last_json_src = last_json_src,
    lines = math.max(src - first_src, 1),
  }
end

return M
