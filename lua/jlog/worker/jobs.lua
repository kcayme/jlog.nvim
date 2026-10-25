local config = require("jlog.config")
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local filter = require("jlog.query.filter")
local json = require("jlog.parse.json")

local M = {}

M.NAMES = { "parse_lines", "count_entries", "scan_lines" }

---Runs in a worker thread: find the JSON object in each line and count the fields of those lines.
---@param payload string vim.mpack of `{ text = string }`, lines joined by "\n"
---@return string vim.mpack of `{ positions = integer[], fields = table }`
M.parse_lines = function(payload)
  local lines, counter, json_at, decoded
  local positions = {}

  lines = vim.split(vim.mpack.decode(payload).text, "\n", { plain = true })
  counter = facets.counter()

  for index, line in ipairs(lines) do
    json_at = nil
    if line:byte(-1) == 13 then
      line = line:sub(1, -2)
    end
    if line:find("%S") then
      json_at, decoded = json.object_at(line)
      if json_at then
        facets.add(counter, entry_model.flatten({ raw = line, body = line, json_at = json_at }, decoded))
      end
    end
    positions[index] = json_at or 0
  end

  return vim.mpack.encode({ positions = positions, fields = counter.fields })
end

---Runs in a worker thread: count the fields of the given entries.
---@param payload string vim.mpack of `{ entries = { { body, json_at, labels }, ... } }`
---@return string vim.mpack of `{ fields = table }`
M.count_entries = function(payload)
  local entries, counter

  entries = vim.mpack.decode(payload).entries
  counter = facets.counter()

  for _, entry in ipairs(entries) do
    facets.add(counter, entry_model.flatten(entry, entry_model.decode(entry)))
  end

  return vim.mpack.encode({ fields = counter.fields })
end

---@class JLogScanSpan
---@field src integer source line of the entry's first line
---@field first integer absolute byte of its first line
---@field last integer absolute byte of its last line's end, continuation lines included

---Runs in a worker thread: the entries of a JSONL chunk that match `filters`, regex terms deferred.
---Lines before the chunk's first JSON line go to `lead`, each matched as a plain entry: the main thread knows whether
---they are plain entries or continue the previous chunk's last entry, as `source.append_lines` decides.
---@param payload string vim.mpack of `{ text, first_src, first_byte, filters, opts = { unwrap, fields, time_utc } }`
---@return string vim.mpack of `{ lead, lead_last, spans, last_json_src, exact }`
M.scan_lines = function(payload)
  local args = vim.mpack.decode(payload)
  local text, src, pos = args.text, args.first_src, args.first_byte
  local lead, spans = {}, {}
  local lead_last = 0
  local index = 1
  local pred, exact, opts, _
  local line, line_end, newline, json_at, decoded, entry, open, last_json_src
  local ctx = {}

  opts =
    config.setup({ unwrap = args.opts.unwrap, fields = args.opts.fields, view = { time_utc = args.opts.time_utc } })
  pred, _, exact = filter.compile(args.filters, { defer_regex = true })
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
        last_json_src = src
        open = pred(ctx) and { src = src, first = pos, last = line_end } or nil
        spans[#spans + 1] = open
      elseif open then
        open.last = line_end
      elseif not last_json_src then
        lead_last = line_end
        decoded = nil
        if pred(ctx) then
          lead[#lead + 1] = { src = src, first = pos, last = line_end }
        end
      end
    end
    pos = pos + (newline - index) + 1
    index = newline + 1
    src = src + 1
  end
  entry, decoded = nil, nil

  return vim.mpack.encode({
    lead = lead,
    lead_last = lead_last,
    spans = spans,
    last_json_src = last_json_src,
    exact = exact,
  })
end

return M
