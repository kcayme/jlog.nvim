-- Matches JSONL lines or array elements of a text slice against a filter, as byte spans; worker-safe.
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local filter = require("jlog.query.filter")
local json = require("jlog.parse.json")
local source = require("jlog.parse.source")

local M = {}

-- spans are flat lists (src, first byte, last byte per entry), which decode far faster than a table per entry

---@class JLogLinesMatch
---@field lead integer[] matching lines before the first JSON line, as plain entries; the caller may join them up
---@field lead_last integer absolute byte where those lines end, 0 when there are none
---@field spans integer[] spans of matching entries from the first JSON line on
---@field last_json_src integer|nil source line of the chunk's last JSON line
---@field lines integer lines in the chunk, blank ones included; an empty chunk is one blank line

---Per picked field of `filters`, its other lines compiled with regex terms deferred; only those with none deferred.
---@param filters string[]
---@return table<string, fun(ctx: JLogMatchCtx): boolean>
M.field_preds = function(filters)
  local preds = {}
  local pred, exact, _

  for name, others in pairs(filter.facet_others(filters)) do
    pred, _, exact = filter.compile(others, { defer_regex = true })
    if exact then
      preds[name] = pred
    end
  end

  return preds
end

---A predicate context reading an entry as the engine does: simple fields from the text, the rest from one decode.
---@param opts JLogOptions
---@return table ctx
---@return fun(entry: JLogEntry, decoded: table|nil) set the entry read next, and its decode when already known
M.entry_ctx = function(opts)
  local ctx = {}
  local current, decoded, decoded_done

  ctx.get = function(path)
    local value, found = entry_model.peek(current, path, opts)

    if found then
      return value
    end
    if not decoded_done then
      decoded, decoded_done = entry_model.decode(current), true
    end

    return entry_model.get(current, decoded, path, opts)
  end

  return ctx,
    function(entry, entry_decoded)
      current, decoded, decoded_done = entry, entry_decoded, entry_decoded ~= nil
      ctx.raw = entry_model.key(entry)
    end
end

---The entries of a JSONL chunk that `pred` accepts, as `source.append_lines` builds them.
---@param text string the chunk, lines joined by "\n"
---@param first_src integer source line of its first line
---@param first_byte integer absolute byte of its first line
---@param pred fun(ctx: JLogMatchCtx): boolean
---@param opts JLogOptions
---@param field_preds table<string, fun(ctx: JLogMatchCtx): boolean>|nil per picked field, its other filter lines
---@param counter JLogFacetCounter|nil counts each picked field's values on the JSON lines its predicate accepts
---@return JLogLinesMatch
M.lines = function(text, first_src, first_byte, pred, opts, field_preds, counter)
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
        for name, field_pred in pairs(field_preds or {}) do
          if field_pred(ctx) then
            facets.add_value(counter, name, ctx.get(name))
          end
        end
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

---The next `count` elements of an array or loki text that `pred` accepts, as spans read back by `source.read_elements`.
---@param text string
---@param pos integer where the element `src` is read from: the `[` for element 1, else its start or the `,` before it
---@param src integer ordinal of that element
---@param count integer
---@param format JLogFormat
---@param pred fun(ctx: JLogMatchCtx): boolean
---@param opts JLogOptions
---@param field_preds table<string, fun(ctx: JLogMatchCtx): boolean>|nil per picked field, its other filter lines
---@param counter JLogFacetCounter|nil counts each picked field's values on the elements its predicate accepts
---@return integer[] spans src, first byte, last byte per matching element
---@return integer|nil next_pos where the element after the last one read is read from; nil at the array's end
---@return integer next_src
---@return string|nil err the text is not a valid array from `next_pos` on
M.elements = function(text, pos, src, count, format, pred, opts, field_preds, counter)
  local spans = {}
  local ctx, set = M.entry_ctx(opts)
  local decoded, read, next_pos, err, size

  local function on_json(_, element_decoded)
    decoded = element_decoded
  end

  for _ = 1, count do
    decoded = nil
    read, next_pos, err = source.read_elements(text, pos, 1, format, src, on_json)
    if err or not read[1] then
      return spans, nil, src, err
    end
    set(read[1], decoded)
    for name, field_pred in pairs(field_preds or {}) do
      if field_pred(ctx) then
        facets.add_value(counter, name, ctx.get(name))
      end
    end
    if pred(ctx) then
      size = #spans
      spans[size + 1], spans[size + 2], spans[size + 3] = src, pos, (next_pos or #text + 1) - 1
    end
    pos, src = next_pos, src + 1
    if not pos then
      break
    end
  end

  return spans, pos, src
end

return M
