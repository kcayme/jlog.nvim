-- JSON decoder that keeps key order and number literals as written.

---@class JLogNode
---@field t "object"|"array"|"string"|"number"|"boolean"|"null"
---@field s integer 1-based start byte offset in the parsed text
---@field e integer 1-based inclusive end byte offset in the parsed text
---@field lit string|nil exact source literal of scalars (strings include quotes; created lazily for strings)
---@field text string|nil strings only: the parsed text `s`/`e` refer to (backs the lazy `lit`)
---@field str string|nil decoded string value
---@field keys string[]|nil decoded object keys, source order, duplicates kept
---@field vals JLogNode[]|nil
---@field inner JLogNode|nil JSON found inside `str` (set by unwrap; offsets relative to `str`)
---@field prefix string|nil text in `str` before `inner` (set by unwrap)

local M = {}

local str_byte, str_find, str_sub = string.byte, string.find, string.sub

local STRING_NODE = {
  __index = function(node, field)
    local lit

    if field ~= "lit" then
      return nil
    end
    lit = str_sub(node.text, node.s, node.e)
    rawset(node, "lit", lit)

    return lit
  end,
}

local BYTE_QUOTE = 34
local BYTE_BACKSLASH = 92
local BYTE_DOT = 46
local BYTE_LOWER_E = 101
local BYTE_UPPER_E = 69
local BYTE_COMMA = 44
local BYTE_COLON = 58
local BYTE_OPEN_BRACKET = 91
local BYTE_CLOSE_BRACKET = 93
local BYTE_OPEN_BRACE = 123
local BYTE_CLOSE_BRACE = 125
local MAX_NESTING = 512
-- shortcut: find tries only the first 8 `{`/`[` positions, raise if real prefixes hold more brackets
local MAX_FIND_CANDIDATES = 8

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

---Slow path of `string_end`, for strings holding a `\"`.
local function escaped_string_end(text, pos)
  local cursor = pos + 1
  local found, backslashes

  while true do
    found = str_find(text, '"', cursor, true)
    if not found then
      return nil
    end
    backslashes = 0
    while str_byte(text, found - backslashes - 1) == BYTE_BACKSLASH do
      backslashes = backslashes + 1
    end
    if backslashes % 2 == 0 then
      return found
    end
    cursor = found + 1
  end
end

---Position of the closing quote of the string opening at `pos`, or nil.
local function string_end(text, pos)
  local found = str_find(text, '"', pos + 1, true)

  -- loop-free fast path: an inner loop here would abort the caller's LuaJIT trace
  if found and str_byte(text, found - 1) == BYTE_BACKSLASH then
    return escaped_string_end(text, pos)
  end

  return found
end

-- shortcut: raw control chars in strings are accepted, strict validation is not needed to display logs
local function decode_string(lit)
  local ok, decoded = pcall(vim.json.decode, lit)

  if not ok then
    return nil
  end

  return decoded
end

local function parse_string(text, pos)
  local found = string_end(text, pos)
  local str

  if not found then
    return nil, "unterminated string at " .. pos
  end

  str = str_sub(text, pos + 1, found - 1)
  if str_find(str, "\\", 1, true) then
    str = decode_string(str_sub(text, pos, found))
    if not str then
      return nil, "invalid string escape at " .. pos
    end
  end

  -- `lit` is created on first access (STRING_NODE): most string literals are never displayed
  return setmetatable({ t = "string", s = pos, e = found, str = str, text = text }, STRING_NODE), found + 1
end

---Object keys need only the decoded text: no node table, no literal.
local function parse_key(text, pos)
  local found = string_end(text, pos)
  local key

  if not found then
    return nil, "unterminated string at " .. pos
  end

  key = str_sub(text, pos + 1, found - 1)
  if str_find(key, "\\", 1, true) then
    key = decode_string(str_sub(text, pos, found))
    if not key then
      return nil, "invalid string escape at " .. pos
    end
  end

  return key, found + 1
end

-- shortcut: leading zeros (`01`) are accepted, the literal is kept verbatim so display is unaffected
local function parse_number(text, pos)
  local _, number_end = str_find(text, "^-?%d+", pos)
  local byte, fraction_end, exponent_end

  if not number_end then
    return fail(text, pos)
  end
  -- byte checks first: most numbers are integers, skip the two pattern finds
  byte = str_byte(text, number_end + 1)
  if byte == BYTE_DOT then
    _, fraction_end = str_find(text, "^%.%d+", number_end + 1)
    number_end = fraction_end or number_end
    byte = str_byte(text, number_end + 1)
  end
  if byte == BYTE_LOWER_E or byte == BYTE_UPPER_E then
    _, exponent_end = str_find(text, "^[eE][-+]?%d+", number_end + 1)
    number_end = exponent_end or number_end
  end

  return { t = "number", s = pos, e = number_end, lit = str_sub(text, pos, number_end) }, number_end + 1
end

---Read `"key":` at `cursor` into `container.keys`.
---@return integer|nil cursor after the colon
---@return string|nil err
local function read_key(text, container, cursor)
  local key, after

  if str_byte(text, cursor) ~= BYTE_QUOTE then
    return fail(text, cursor)
  end
  key, after = parse_key(text, cursor)
  if not key then
    return nil, after
  end
  after = skip_ws(text, after)
  if str_byte(text, after) ~= BYTE_COLON then
    return fail(text, after)
  end
  container.keys[#container.keys + 1] = key

  return after + 1
end

---Iterative (explicit stack) so LuaJIT can trace it: recursive descent runs interpreted.
parse_value = function(text, pos)
  local stack = {}
  local depth = 0
  local cursor = pos
  local node, after, byte, literal, container, close_byte, err

  while true do
    cursor = skip_ws(text, cursor)
    byte = str_byte(text, cursor)
    node = nil
    if byte == BYTE_QUOTE then
      node, after = parse_string(text, cursor)
    elseif byte == BYTE_OPEN_BRACE or byte == BYTE_OPEN_BRACKET then
      if depth >= MAX_NESTING then
        return nil, "nesting too deep at " .. cursor
      end
      close_byte = byte == BYTE_OPEN_BRACE and BYTE_CLOSE_BRACE or BYTE_CLOSE_BRACKET
      container = { t = byte == BYTE_OPEN_BRACE and "object" or "array", s = cursor, vals = {} }
      if byte == BYTE_OPEN_BRACE then
        container.keys = {}
      end
      after = skip_ws(text, cursor + 1)
      if str_byte(text, after) == close_byte then
        container.e = after
        node, after = container, after + 1
      else
        depth = depth + 1
        stack[depth] = container
        cursor = after
        if container.keys then
          cursor, err = read_key(text, container, cursor)
          if not cursor then
            return nil, err
          end
        end
      end
    else
      literal = LITERALS[byte]
      if literal then
        if str_sub(text, cursor, cursor + #literal.word - 1) ~= literal.word then
          return fail(text, cursor)
        end
        node = { t = literal.type, s = cursor, e = cursor + #literal.word - 1, lit = literal.word }
        after = cursor + #literal.word
      else
        node, after = parse_number(text, cursor)
      end
    end

    -- a finished value: attach it to its parents, closing every container that ends right after it
    if node then
      while true do
        if depth == 0 then
          return node, after
        end
        container = stack[depth]
        container.vals[#container.vals + 1] = node
        cursor = skip_ws(text, after)
        byte = str_byte(text, cursor)
        if byte == (container.keys and BYTE_CLOSE_BRACE or BYTE_CLOSE_BRACKET) then
          container.e = cursor
          stack[depth] = nil
          depth = depth - 1
          node, after = container, cursor + 1
        elseif byte ~= BYTE_COMMA then
          return fail(text, cursor)
        else
          cursor = skip_ws(text, cursor + 1)
          if container.keys then
            cursor, err = read_key(text, container, cursor)
            if not cursor then
              return nil, err
            end
          end
          break
        end
      end
    elseif not after or type(after) == "string" then
      return nil, after
    end
  end
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
  -- cheap plain-find prefilter: most strings hold no bracket at all
  if not str_find(node.str, "{", 1, true) and not str_find(node.str, "[", 1, true) then
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

---Find an object/array in `text`: from the first `{` or `[` (left to right) that parses through to the end.
---@param text string
---@return JLogNode|nil node offsets relative to `text`
---@return string|nil prefix_or_err text before the JSON (`""` when the whole text is JSON), or an error message
M.find = function(text)
  local start = str_find(text, "[{[]")
  local candidates = 0
  local node, err, prefix

  if not start then
    return nil, "no object or array found"
  end
  while start and candidates < MAX_FIND_CANDIDATES do
    node, err = parse_all_from(text, start)
    if node then
      break
    end
    candidates = candidates + 1
    start = str_find(text, "[{[]", start + 1)
  end
  if not node then
    return nil, err or "no object or array found"
  end

  prefix = str_sub(text, 1, start - 1)
  if str_find(prefix, "^%s*$") then
    prefix = ""
  end

  return node, prefix
end

---Fast path for jsonl lines: the first `{` in `text` and the `vim.json.decode` of everything from it, when that is a table.
---@param text string
---@return integer|nil pos byte position of the first `{`
---@return table|nil decoded
M.object_at = function(text)
  local pos = str_find(text, "{", 1, true)
  local ok
  local decoded

  if not pos then
    return nil, nil
  end

  ok, decoded = pcall(vim.json.decode, str_sub(text, pos))
  if not ok or type(decoded) ~= "table" then
    return nil, nil
  end

  return pos, decoded
end

---Recursively attach `inner`/`prefix` to string nodes that contain JSON, in place.
---@param node JLogNode
---@param max_depth integer maximum number of string-in-string layers to unwrap
---@return JLogNode node
M.unwrap = function(node, max_depth)
  return unwrap_at(node, 0, max_depth)
end

return M
