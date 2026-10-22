---@class JLogNode
---@field t "object"|"array"|"string"|"number"|"boolean"|"null"
---@field s integer 1-based start byte offset in the parsed text
---@field e integer 1-based inclusive end byte offset in the parsed text
---@field lit string|nil exact source literal of scalars (strings include quotes)
---@field str string|nil decoded string value
---@field keys string[]|nil decoded object keys, source order, duplicates kept
---@field vals JLogNode[]|nil
---@field inner JLogNode|nil JSON found inside `str` (set by unwrap; offsets relative to `str`)
---@field prefix string|nil text in `str` before `inner` (set by unwrap)

local M = {}

local str_byte, str_find, str_sub = string.byte, string.find, string.sub

local BYTE_QUOTE = 34
local BYTE_COMMA = 44
local BYTE_COLON = 58
local BYTE_OPEN_BRACKET = 91
local BYTE_CLOSE_BRACKET = 93
local BYTE_OPEN_BRACE = 123
local BYTE_CLOSE_BRACE = 125

local LITERALS = {
  [string.byte("t")] = { word = "true", type = "boolean" },
  [string.byte("f")] = { word = "false", type = "boolean" },
  [string.byte("n")] = { word = "null", type = "null" },
}

local parse_value

local function skip_ws(text, pos)
  local byte = str_byte(text, pos)

  -- fast path: compact JSONL rarely has whitespace between tokens
  if not byte or byte > 32 then
    return pos
  end
  local _, ws_end = str_find(text, "^[ \t\r\n]*", pos)

  return ws_end + 1
end

local function fail(text, pos)
  if pos > #text then
    return nil, "unexpected end of input"
  end

  return nil, string.format("unexpected character %q at %d", str_sub(text, pos, pos), pos)
end

local function parse_string(text, pos)
  local cursor = pos + 1
  local has_escape = false
  local found, lit, str

  while true do
    found = str_find(text, '["\\]', cursor)
    if not found then
      return nil, "unterminated string at " .. pos
    end
    if str_byte(text, found) == BYTE_QUOTE then
      break
    end
    has_escape = true
    cursor = found + 2
  end

  lit = str_sub(text, pos, found)
  if has_escape then
    local ok, decoded = pcall(vim.json.decode, lit)
    if not ok then
      return nil, "invalid string escape at " .. pos
    end
    str = decoded
  else
    str = str_sub(lit, 2, -2)
  end

  return { t = "string", s = pos, e = found, lit = lit, str = str }, found + 1
end

local function parse_number(text, pos)
  local _, number_end = str_find(text, "^-?%d+", pos)
  local fraction_end, exponent_end

  if not number_end then
    return fail(text, pos)
  end
  _, fraction_end = str_find(text, "^%.%d+", number_end + 1)
  number_end = fraction_end or number_end
  _, exponent_end = str_find(text, "^[eE][-+]?%d+", number_end + 1)
  number_end = exponent_end or number_end

  return { t = "number", s = pos, e = number_end, lit = str_sub(text, pos, number_end) }, number_end + 1
end

local function parse_container(text, pos, is_object)
  local close_byte = is_object and BYTE_CLOSE_BRACE or BYTE_CLOSE_BRACKET
  local node = { t = is_object and "object" or "array", s = pos, keys = is_object and {} or nil, vals = {} }
  local cursor = skip_ws(text, pos + 1)
  local byte, key, value, after_or_err

  if str_byte(text, cursor) == close_byte then
    node.e = cursor

    return node, cursor + 1
  end

  while true do
    if is_object then
      if str_byte(text, cursor) ~= BYTE_QUOTE then
        return fail(text, cursor)
      end
      key, cursor = parse_string(text, cursor)
      if not key then
        return nil, cursor
      end
      cursor = skip_ws(text, cursor)
      if str_byte(text, cursor) ~= BYTE_COLON then
        return fail(text, cursor)
      end
      node.keys[#node.keys + 1] = key.str
      cursor = cursor + 1
    end

    value, after_or_err = parse_value(text, cursor)
    if not value then
      return nil, after_or_err
    end
    node.vals[#node.vals + 1] = value
    cursor = skip_ws(text, after_or_err)

    byte = str_byte(text, cursor)
    if byte == close_byte then
      node.e = cursor

      return node, cursor + 1
    end
    if byte ~= BYTE_COMMA then
      return fail(text, cursor)
    end
    cursor = skip_ws(text, cursor + 1)
  end
end

parse_value = function(text, pos)
  local cursor = skip_ws(text, pos)
  local byte = str_byte(text, cursor)
  local literal = LITERALS[byte]

  if byte == BYTE_QUOTE then
    return parse_string(text, cursor)
  end
  if byte == BYTE_OPEN_BRACE or byte == BYTE_OPEN_BRACKET then
    return parse_container(text, cursor, byte == BYTE_OPEN_BRACE)
  end
  if literal then
    if str_sub(text, cursor, cursor + #literal.word - 1) ~= literal.word then
      return fail(text, cursor)
    end

    return { t = literal.type, s = cursor, e = cursor + #literal.word - 1, lit = literal.word }, cursor + #literal.word
  end

  return parse_number(text, cursor)
end

local function parse_all_from(text, pos)
  local node, after = parse_value(text, pos)

  if not node then
    return nil, after
  end
  after = skip_ws(text, after)
  if after <= #text then
    return fail(text, after)
  end

  return node, nil
end

local function unwrap_at(node, depth, max_depth)
  local inner, prefix

  if node.vals then
    for _, value in ipairs(node.vals) do
      unwrap_at(value, depth, max_depth)
    end

    return node
  end
  if node.t ~= "string" or depth >= max_depth then
    return node
  end

  inner, prefix = M.find(node.str)
  if inner then
    node.inner = inner
    node.prefix = prefix
    unwrap_at(inner, depth + 1, max_depth)
  end

  return node
end

---Parse one JSON value starting at the first non-whitespace at `pos`.
---@param text string
---@param pos integer|nil defaults to 1
---@return JLogNode|nil node
---@return integer|string after_or_err position after the value, or an error message
M.parse = function(text, pos)
  return parse_value(text, pos or 1)
end

---Parse `text` as exactly one JSON value; only whitespace may surround it.
---@param text string
---@return JLogNode|nil node
---@return string|nil err
M.parse_all = function(text)
  return parse_all_from(text, 1)
end

---Find an object/array in `text`: the whole trimmed text, else from the first `{` or `[` to the end.
---@param text string
---@return JLogNode|nil node offsets relative to `text`
---@return string|nil prefix_or_err text before the JSON (`""` when the whole text is JSON), or an error message
M.find = function(text)
  local start = str_find(text, "[{[]")
  local node, err, prefix

  if not start then
    return nil, "no object or array found"
  end
  node, err = parse_all_from(text, start)
  if not node then
    return nil, err
  end

  prefix = str_sub(text, 1, start - 1)
  if str_find(prefix, "^%s*$") then
    prefix = ""
  end

  return node, prefix
end

---Recursively attach `inner`/`prefix` to string nodes that contain JSON, in place.
---@param node JLogNode
---@param max_depth integer maximum number of string-in-string layers to unwrap
---@return JLogNode node
M.unwrap = function(node, max_depth)
  return unwrap_at(node, 0, max_depth)
end

return M
