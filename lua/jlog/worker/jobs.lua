local json = require("jlog.parse.json")
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")

local M = {}

M.NAMES = { "parse_lines", "count_entries" }

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

return M
