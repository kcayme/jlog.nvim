local json = require("jlog.parse.json")

local str_byte, str_find, str_sub = string.byte, string.find, string.sub

local M = {}

local ALIAS_FIELDS = { time = "time", level = "level", msg = "message" }
-- doubles hold every integer below this exactly; vim.json.decode rounds bigger ones (and clamps past 2^63)
local EXACT_LIMIT = 2 ^ 53

-- `get` runs per entry per field: split each dotted path once (paths are few: filter, group and facet fields)
local path_segments = setmetatable({}, {
  __index = function(cache, path)
    local segments = vim.split(path, ".", { plain = true })

    rawset(cache, path, segments)

    return segments
  end,
})

-- whether `peek` may read a path: no alias, no dot, no character a key could only spell with an escape
local peekable = setmetatable({}, {
  __index = function(cache, path)
    local simple = not ALIAS_FIELDS[path] and path:find('^[^%c"\\/.]+$') ~= nil

    rawset(cache, path, simple)

    return simple
  end,
})

---@param text string
---@param pos integer
---@return integer pos first byte at or after `pos` that is not JSON whitespace
local function skip_space(text, pos)
  local byte = str_byte(text, pos)

  while byte == 32 or byte == 9 or byte == 10 or byte == 13 do
    pos = pos + 1
    byte = str_byte(text, pos)
  end

  return pos
end

---@param text string
---@param bracket string
---@param from integer
---@param before integer
---@return boolean
local function opens_before(text, bracket, from, before)
  local found = str_find(text, bracket, from, true)

  return found ~= nil and found < before
end

---Resolve the first path segment: a real key wins, otherwise the first configured alias present.
---@param decoded table
---@param segment string
---@param opts JLogOptions
---@return string
local function resolve_key(decoded, segment, opts)
  local aliases = ALIAS_FIELDS[segment] and opts.fields[ALIAS_FIELDS[segment]]

  if decoded[segment] ~= nil or not aliases then
    return segment
  end
  for _, alias in ipairs(aliases) do
    if decoded[alias] ~= nil then
      return alias
    end
  end

  return segment
end

---@param value any
---@return boolean
local function is_inexact(value)
  return type(value) == "number" and (value >= EXACT_LIMIT or value <= -EXACT_LIMIT)
end

---Lua value of a parsed node, like vim.json.decode, but integers too big for a double keep their literal text.
---@param node JLogNode
---@return any
local function to_lua(node)
  local value
  local kind = node.t

  if kind == "object" or kind == "array" then
    value = {}
    for index, child in ipairs(node.vals) do
      value[kind == "object" and node.keys[index] or index] = to_lua(child)
    end

    return value
  end
  if kind == "number" then
    value = tonumber(node.lit)

    return (is_inexact(value) and node.lit:find("^%-?%d+$")) and node.lit or value
  end
  if kind == "null" then
    return vim.NIL
  end
  if kind == "boolean" then
    return node.lit == "true"
  end

  return node.str
end

---Decode JSON hidden inside a string value, or nil when there is none.
---@param text string
---@return table|nil
local function unwrap_string(text)
  local node = json.find(text)
  local ok, value

  if not node then
    return nil
  end
  ok, value = pcall(vim.json.decode, text:sub(node.s, node.e))
  if not ok or type(value) ~= "table" then
    return nil
  end

  return value
end

---`unwrap_string` with big integers kept exact.
---@param text string
---@return table|nil
local function unwrap_string_exact(text)
  local node = json.find(text)

  if not node or (node.t ~= "object" and node.t ~= "array") then
    return nil
  end

  return to_lua(node)
end

---@param prefix string
---@param value table
---@param out table<string, any>
---@return boolean inexact a number may have been rounded by the decoder
local function flatten_into(prefix, value, out)
  local inexact = false

  for key, child in pairs(value) do
    if type(child) == "table" and not vim.islist(child) then
      inexact = flatten_into(prefix .. key .. ".", child, out) or inexact
    elseif type(child) ~= "table" and child ~= vim.NIL then
      out[prefix .. key] = child
      inexact = inexact or is_inexact(child)
    end
  end

  return inexact
end

---@param entry JLogEntry
---@param decoded table|nil
---@param path string
---@param opts JLogOptions
---@param unwrap fun(text: string): table|nil
---@return any
local function lookup(entry, decoded, path, opts, unwrap)
  local segments = path_segments[path]
  local current = decoded
  local depth = 0
  local label_key

  if path:sub(1, 7) == "labels." then
    label_key = path:sub(8)
    if label_key == "_ts" then
      return entry.ts
    end

    return entry.labels and entry.labels[label_key]
  end

  for index, segment in ipairs(segments) do
    if type(current) == "string" and opts.unwrap.enable and depth < opts.unwrap.max_depth then
      current = unwrap(current)
      depth = depth + 1
    end
    if type(current) ~= "table" then
      return nil
    end
    current = current[index == 1 and resolve_key(current, segment, opts) or segment]
    if current == vim.NIL then
      return nil
    end
  end

  return current
end

---Text of a decoded scalar: integers in full, other numbers in the fewest digits that read back the same.
---@param value any
---@return string
M.text = function(value)
  local text

  if type(value) ~= "number" then
    return tostring(value)
  end
  if value % 1 == 0 and not is_inexact(value) then
    return string.format("%d", value)
  end
  for digits = 15, 16 do
    text = string.format("%." .. digits .. "g", value)
    if tonumber(text) == value then
      return text
    end
  end

  return string.format("%.17g", value)
end

---`get` of a simple top-level field, read from the text without decoding; `nil, false` unless provably the same.
---@param entry JLogEntry
---@param path string
---@param _opts JLogOptions unused: alias fields are declined rather than resolved
---@return any value
---@return boolean found
M.peek = function(entry, path, _opts)
  local body, json_at = entry.body, entry.json_at
  local key_at, key_end, value_at, value_end, escape_at, digits_at, byte

  -- \u could spell the key another way; plain finds only: pattern finds stop LuaJIT from compiling the scan
  if not json_at or not peekable[path] or str_find(body, "\\u", json_at, true) then
    return nil, false
  end
  -- the Lua parser accepts NUL in array elements but vim.json.decode does not, so `get` sees no fields
  if str_find(body, "\0", json_at, true) then
    return nil, false
  end
  key_at, key_end = str_find(body, path, json_at, true)
  if not key_at or str_find(body, path, key_end + 1, true) then
    return nil, false
  end
  -- an unescaped opening quote, with no object or array opened before it: a top-level key
  if str_byte(body, key_at - 1) ~= 34 or str_byte(body, key_at - 2) == 92 or str_byte(body, key_end + 1) ~= 34 then
    return nil, false
  end
  if opens_before(body, "{", json_at + 1, key_at) or opens_before(body, "[", json_at + 1, key_at) then
    return nil, false
  end
  value_at = skip_space(body, key_end + 2)
  if str_byte(body, value_at) ~= 58 then
    return nil, false
  end
  value_at = skip_space(body, value_at + 1)
  byte = str_byte(body, value_at)

  if byte == 34 then
    value_end = str_find(body, '"', value_at + 1, true)
    escape_at = str_find(body, "\\", value_at + 1, true)
    if not value_end or (escape_at and escape_at < value_end) then
      return nil, false
    end

    return str_sub(body, value_at + 1, value_end - 1), true
  end

  digits_at = byte == 45 and value_at + 1 or value_at
  value_end = digits_at
  byte = str_byte(body, value_end)
  while byte and byte >= 48 and byte <= 57 do
    value_end = value_end + 1
    byte = str_byte(body, value_end)
  end
  -- 15 digits stay below 2^53; a fraction or exponent may round
  if value_end == digits_at or value_end - digits_at > 15 or byte == 46 or byte == 101 or byte == 69 then
    return nil, false
  end

  return tonumber(str_sub(body, value_at, value_end - 1)), true
end

---Like `decode`, but integers too big for a double are kept as their literal text (slower: Lua parser).
---@param entry JLogEntry
---@return table|nil
M.decode_exact = function(entry)
  local node

  if not entry.json_at then
    return nil
  end
  node = json.parse_all(entry.body:sub(entry.json_at))
  if not node or (node.t ~= "object" and node.t ~= "array") then
    return nil
  end

  return to_lua(node)
end

---Parsed (and unwrapped, per `opts.unwrap`) tree of the entry's JSON, plus the text before it.
---@param entry JLogEntry
---@param opts JLogOptions
---@return JLogNode|nil node
---@return string prefix
M.tree = function(entry, opts)
  local node

  if not entry.json_at then
    return nil, ""
  end

  node = json.parse_all(entry.body:sub(entry.json_at))
  if not node then
    return nil, ""
  end
  if opts.unwrap.enable then
    json.unwrap(node, opts.unwrap.max_depth)
  end

  return node, entry.body:sub(1, entry.json_at - 1)
end

---@param entry JLogEntry
---@return table|nil
M.decode = function(entry)
  local ok, value

  if not entry.json_at then
    return nil
  end
  ok, value = pcall(vim.json.decode, entry.body:sub(entry.json_at))
  if not ok or type(value) ~= "table" then
    return nil
  end

  return value
end

---@param entry JLogEntry
---@param decoded table|nil
---@param path string dotted path
---@param opts JLogOptions
---@return any
M.get = function(entry, decoded, path, opts)
  local value = lookup(entry, decoded, path, opts, unwrap_string)

  -- rare: the decoder may have rounded this number, read its literal instead
  if is_inexact(value) then
    return lookup(entry, M.decode_exact(entry), path, opts, unwrap_string_exact)
  end

  return value
end

---Dotted path to scalar for every field, including labels. Arrays and nulls are skipped.
---@param entry JLogEntry
---@param decoded table|nil
---@return table<string, any>
M.flatten = function(entry, decoded)
  local out = {}

  if decoded and flatten_into("", decoded, out) then
    -- rare: the decoder may have rounded a number, take the literals instead
    out = {}
    flatten_into("", M.decode_exact(entry) or {}, out)
  end
  for key, value in pairs(entry.labels or {}) do
    out["labels." .. key] = value
  end

  return out
end

---Identity across reloads (not `src`, which shifts when lines are inserted above).
---@param entry JLogEntry
---@return string
M.key = function(entry)
  if not entry.cont then
    return entry.raw
  end

  return entry.raw .. "\n" .. table.concat(entry.cont, "\n")
end

return M
