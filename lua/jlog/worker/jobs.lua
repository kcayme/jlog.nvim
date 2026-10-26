-- Jobs run inside worker threads: parse lines, count fields, match lines or elements.
local config = require("jlog.config")
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local filter = require("jlog.query.filter")
local json = require("jlog.parse.json")
local match = require("jlog.query.match")

local M = {}

M.NAMES = { "parse_lines", "count_entries", "match_lines", "match_elements" }

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

---Runs in a worker thread: the entries of a JSONL chunk that match `filters`, regex terms deferred (see `match.lines`).
---@param payload string vim.mpack of `{ text, first_src, first_byte, filters, opts = { unwrap, fields, time_utc } }`
---@return string vim.mpack of a `JLogLinesMatch` plus `exact` and `values`, picked fields' counts (`match.field_preds`)
M.match_lines = function(payload)
  local args = vim.mpack.decode(payload)
  local counter = facets.counter()
  local opts, pred, result, exact, _

  opts =
    config.setup({ unwrap = args.opts.unwrap, fields = args.opts.fields, view = { time_utc = args.opts.time_utc } })
  pred, _, exact = filter.compile(args.filters, { defer_regex = true })
  result = match.lines(args.text, args.first_src, args.first_byte, pred, opts, match.field_preds(args.filters), counter)
  result.exact, result.values = exact, counter.fields

  return vim.mpack.encode(result)
end

---Runs in a worker thread: the elements of an array or loki chunk that match `filters`, regex terms deferred.
---@param payload string vim.mpack of `{ text, first_src, first_byte, count, format, filters, opts }`, as `match_lines`
---@return string vim.mpack of `{ spans, values }`: spans in absolute bytes (`match.elements`), picked fields' counts
M.match_elements = function(payload)
  local args = vim.mpack.decode(payload)
  local counter = facets.counter()
  local offset = args.first_byte - 1
  local opts, pred, spans, err, _

  opts =
    config.setup({ unwrap = args.opts.unwrap, fields = args.opts.fields, view = { time_utc = args.opts.time_utc } })
  pred = filter.compile(args.filters, { defer_regex = true })
  spans, _, _, err = match.elements(
    args.text,
    1,
    args.first_src,
    args.count,
    args.format,
    pred,
    opts,
    match.field_preds(args.filters),
    counter
  )
  -- a broken array fails the job: the main thread scans on and stops where the array breaks
  if err then
    error(err, 0)
  end
  for at = 2, #spans, 3 do
    spans[at], spans[at + 1] = spans[at] + offset, spans[at + 1] + offset
  end

  return vim.mpack.encode({ spans = spans, values = counter.fields })
end

return M
