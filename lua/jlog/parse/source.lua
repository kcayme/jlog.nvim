local json = require("jlog.parse.json")

---@class JLogEntry
---@field src integer source line (jsonl) or 1-based element index (loki/array)
---@field raw string exact source text of the line/element, `\r` stripped
---@field body string log text
---@field json_at integer|nil byte in `body` where the JSON object starts; nil = plain
---@field labels table<string,string>|nil
---@field ts string|nil Loki nanosecond timestamp
---@field cont string[]|nil continuation lines

local M = {}

---@param body string
---@return integer|nil
local function find_json_at(body)
  local json_at = body:find("{", 1, true)
  local ok
  local decoded

  if not json_at then
    return nil
  end

  ok, decoded = pcall(vim.json.decode, body:sub(json_at))
  if not ok or type(decoded) ~= "table" then
    return nil
  end

  return json_at
end

---@param node JLogNode
---@param key string
---@return JLogNode|nil
local function field_of(node, key)
  for index, candidate in ipairs(node.keys) do
    if candidate == key then
      return node.vals[index]
    end
  end

  return nil
end

---@param node JLogNode|nil
---@return string
local function scalar_text(node)
  if not node then
    return ""
  end

  return node.str or node.lit or ""
end

---@param node JLogNode
---@param text string
---@param index integer
---@return JLogEntry
local function loki_entry(node, text, index)
  local raw = text:sub(node.s, node.e)
  local fields = node.t == "object" and field_of(node, "fields") or nil
  local line_node = node.t == "object" and field_of(node, "line") or nil
  local entry = { src = index, raw = raw, body = raw }

  if not line_node then
    return entry
  end

  entry.body = scalar_text(line_node):gsub("\n$", "")
  entry.json_at = find_json_at(entry.body)
  entry.ts = scalar_text(field_of(node, "timestamp"))
  entry.labels = {}
  if fields and fields.t == "object" then
    for label_index, label_key in ipairs(fields.keys) do
      entry.labels[label_key] = scalar_text(fields.vals[label_index])
    end
  end

  return entry
end

---@param left JLogEntry
---@param right JLogEntry
---@return boolean
local function older_first(left, right)
  local left_ts = left.ts or ""
  local right_ts = right.ts or ""

  if #left_ts ~= #right_ts then
    return #left_ts < #right_ts
  end
  if left_ts ~= right_ts then
    return left_ts < right_ts
  end

  return left.src < right.src
end

---@param text string
---@param format JLogFormat
---@return JLogEntry[]|nil
---@return string|nil err
local function build_elements(text, format)
  local root, err = json.parse_all(text)
  local entries = {}
  local raw

  if not root then
    return nil, err
  end
  if root.t ~= "array" then
    return nil, "expected a JSON array"
  end

  for index, node in ipairs(root.vals) do
    if format == "loki" then
      entries[index] = loki_entry(node, text, index)
    else
      raw = text:sub(node.s, node.e)
      entries[index] = { src = index, raw = raw, body = raw, json_at = node.t == "object" and 1 or nil }
    end
  end
  if format == "loki" then
    table.sort(entries, older_first)
  end

  return entries
end

---Appends jsonl lines as entries: JSON lines (optionally after a text prefix) start an entry, plain lines
---continue the previous JSON entry or become plain entries, blank lines are skipped.
---@param entries JLogEntry[] mutated
---@param lines string[]
---@param first_lnum integer source line number of `lines[1]`
M.append_lines = function(entries, lines, first_lnum)
  local last
  local json_at

  for index, line in ipairs(lines) do
    line = line:gsub("\r$", "")
    if line:find("%S") then
      last = entries[#entries]
      json_at = find_json_at(line)
      if not json_at and last and last.json_at then
        last.cont = last.cont or {}
        table.insert(last.cont, line)
      else
        table.insert(entries, { src = first_lnum + index - 1, raw = line, body = line, json_at = json_at })
      end
    end
  end
end

---@param text string
---@param format JLogFormat
---@return JLogEntry[]|nil
---@return string|nil err
M.build = function(text, format)
  local entries = {}

  if text == "" then
    return entries
  end
  if format == "jsonl" then
    M.append_lines(entries, vim.split(text, "\n", { plain = true }), 1)

    return entries
  end

  return build_elements(text, format)
end

return M
