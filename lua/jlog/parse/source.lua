local json = require("jlog.parse.json")
local pages = require("jlog.parse.pages")
local utils = require("jlog.utils")

---@class JLogEntry
---@field src integer source line (jsonl) or 1-based element index (loki/array)
---@field raw string exact source text of the line/element, `\r` stripped
---@field body string log text
---@field json_at integer|nil byte in `body` where the JSON object starts; nil = plain
---@field labels table<string,string>|nil
---@field ts string|nil Loki nanosecond timestamp
---@field cont string[]|nil continuation lines

local M = {}

local BYTE_OPEN_BRACKET = 91
local BYTE_CLOSE_BRACKET = 93
local BYTE_COMMA = 44
local BYTE_OPEN_BRACE = 123
-- only a real key matches: inside a JSON string these quotes would be escaped
local TIMESTAMP_PATTERN = '"timestamp"%s*:%s*"(%d+)"'
-- entries with the same labels share one table; past this many distinct sets, new ones are not remembered
local MAX_LABEL_SETS = 4096
-- marks the label table at the end of a path through `label_sets`
local LEAF = {}

-- label sets seen so far, as a trie alternating label keys and values
local label_sets = {}
local label_set_count = 0

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

---@param node table trie node
---@param name string
---@param create boolean
---@return table|nil
local function trie_step(node, name, create)
  local child = node[name]

  if not child and create then
    child = {}
    node[name] = child
  end

  return child
end

---`labels`, or an equal label set seen earlier: entries with the same labels share one table.
---@param labels table<string, string>
---@return table<string, string>
local function shared_labels(labels)
  local create = label_set_count < MAX_LABEL_SETS
  local node = label_sets

  for label_key, value in pairs(labels) do
    node = node and trie_step(node, label_key, create)
    node = node and trie_step(node, value, create)
  end
  if not node then
    return labels
  end
  if not node[LEAF] then
    node[LEAF] = labels
    label_set_count = label_set_count + 1
  end

  return node[LEAF]
end

---@param node JLogNode
---@param text string
---@param index integer
---@return JLogEntry
---@return table|nil decoded the decoded log line, when it is JSON
local function loki_entry(node, text, index)
  local raw = text:sub(node.s, node.e)
  local fields = node.t == "object" and field_of(node, "fields") or nil
  local line_node = node.t == "object" and field_of(node, "line") or nil
  local entry = { src = index, raw = raw, body = raw }
  local decoded

  if not line_node then
    return entry
  end

  entry.body = scalar_text(line_node):gsub("\n$", "")
  entry.json_at, decoded = json.object_at(entry.body)
  entry.ts = scalar_text(field_of(node, "timestamp"))
  entry.labels = {}
  if fields and fields.t == "object" then
    for label_index, label_key in ipairs(fields.keys) do
      entry.labels[label_key] = scalar_text(fields.vals[label_index])
    end
    entry.labels = shared_labels(entry.labels)
  end

  return entry, decoded
end

---Whether `key` occurs as `"key"` more than once in `raw`.
---@param raw string
---@param key string
---@return boolean
local function repeated(raw, key)
  local _, last = raw:find('"' .. key .. '"', 1, true)

  return last ~= nil and raw:find('"' .. key .. '"', last + 1, true) ~= nil
end

---A loki element read with one C decode instead of a node tree; nil when that could differ from `loki_entry`.
---@param raw string the element's exact text
---@param index integer
---@return JLogEntry|nil
---@return table|nil decoded the decoded log line, when it is JSON
local function fast_loki_entry(raw, index)
  local ok, element, labels, entry, decoded

  -- unicode escapes, duplicate keys and non-string values are left to the exact parser
  if raw:byte(1) ~= BYTE_OPEN_BRACE or raw:find("\\u", 1, true) or repeated(raw, "line") or repeated(raw, "fields") then
    return nil
  end
  ok, element = pcall(vim.json.decode, raw)
  if not ok or type(element) ~= "table" or type(element.line) ~= "string" or type(element.timestamp) ~= "string" then
    return nil
  end
  if repeated(raw, "timestamp") or (element.fields ~= nil and type(element.fields) ~= "table") then
    return nil
  end
  labels = element.fields or {}
  for _, value in pairs(labels) do
    if type(value) ~= "string" then
      return nil
    end
  end
  entry = { src = index, raw = raw, body = element.line:gsub("\n$", ""), ts = element.timestamp }
  entry.json_at, decoded = json.object_at(entry.body)
  entry.labels = next(labels) and shared_labels(labels) or {}

  return entry, decoded
end

---@param node JLogNode
---@param text string
---@param index integer
---@param format JLogFormat
---@return JLogEntry
---@return table|nil decoded the decoded log line, when it is JSON (loki only)
local function element_entry(node, text, index, format)
  local raw

  if format == "loki" then
    return loki_entry(node, text, index)
  end
  raw = text:sub(node.s, node.e)

  return { src = index, raw = raw, body = raw, json_at = node.t == "object" and 1 or nil }
end

local skip_space = utils.skip_space

---@param text string
---@param pos integer at the array's closing `]`
---@return string|nil err when anything but whitespace follows
local function array_end(text, pos)
  if skip_space(text, pos + 1) <= #text then
    return string.format("unexpected character after the array at %d", pos + 1)
  end

  return nil
end

---The last loki timestamp in `text`, searched for in a tail window that grows until it holds one.
---@param text string
---@return string|nil
local function last_timestamp(text)
  local window = 4096
  local from, last, stamp, match_end

  repeat
    from = math.max(1, #text - window)
    match_end, stamp = select(2, text:find(TIMESTAMP_PATTERN, from))
    while match_end do
      last = stamp
      match_end, stamp = select(2, text:find(TIMESTAMP_PATTERN, match_end + 1))
    end
    window = window * 4
  until last or from == 1

  return last
end

---@param left string|nil
---@param right string|nil
---@return boolean
local function ts_less(left, right)
  left, right = left or "", right or ""
  if #left ~= #right then
    return #left < #right
  end

  return left < right
end

---@param left JLogEntry
---@param right JLogEntry
---@return boolean
local function older_first(left, right)
  if left.ts ~= right.ts then
    return ts_less(left.ts, right.ts)
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

  if not root then
    return nil, err
  end
  if root.t ~= "array" then
    return nil, "expected a JSON array"
  end

  for index, node in ipairs(root.vals) do
    entries[index] = element_entry(node, text, index, format)
  end
  if format == "loki" then
    table.sort(entries, older_first)
  end

  return entries
end

---Append jsonl lines: JSON lines start entries, plain lines continue the last JSON entry, blank lines are skipped.
---@param entries JLogEntry[] mutated
---@param lines string[]
---@param first_lnum integer source line number of `lines[1]`
---@param on_json fun(entry: JLogEntry, decoded: table)|nil called with each new JSON entry and its decoded object
M.append_lines = function(entries, lines, first_lnum, on_json)
  local last
  local json_at, decoded
  local entry

  for index, line in ipairs(lines) do
    line = line:gsub("\r$", "")
    if line:find("%S") then
      last = entries[#entries]
      json_at, decoded = json.object_at(line)
      if not json_at and last and last.json_at then
        last.cont = last.cont or {}
        table.insert(last.cont, line)
      else
        entry = { src = first_lnum + index - 1, raw = line, body = line, json_at = json_at }
        table.insert(entries, entry)
        if json_at and on_json then
          on_json(entry, decoded)
        end
      end
    end
  end
end

---Up to `count` lines of `text` from `pos`, stopping once past `stop`; the last line may lack its newline.
---@param text string
---@param pos integer
---@param count integer
---@param stop integer last byte to read
---@return string[] lines
---@return integer next_pos
M.take_lines = function(text, pos, count, stop)
  local lines = {}
  local newline

  for _ = 1, count do
    if pos > stop then
      break
    end
    newline = text:find("\n", pos, true)
    if not newline then
      lines[#lines + 1] = text:sub(pos)
      pos = #text + 1

      break
    end
    lines[#lines + 1] = text:sub(pos, newline - 1)
    pos = newline + 1
  end

  return lines, pos
end

M.older_first = older_first

---Read up to `count` elements of a JSON array, one `json.parse` per element, so no whole-array tree is built.
---@param text string
---@param pos integer at the array's `[` when `first_index` is 1, else after an element or its comma
---@param count integer
---@param format JLogFormat
---@param first_index integer `src` of the first element read
---@param on_json fun(entry: JLogEntry, decoded: table|nil)|nil called with each entry and its decoded loki line
---@return JLogEntry[] entries
---@return integer|nil next_pos nil once the closing `]` is reached; after an error, where the unparsed rest starts
---@return string|nil err
M.read_elements = function(text, pos, count, format, first_index, on_json)
  local entries = {}
  local node, after, entry, decoded, err

  pos = skip_space(text, pos)
  if first_index == 1 then
    if text:byte(pos) ~= BYTE_OPEN_BRACKET then
      return entries, pos, "expected a JSON array"
    end
    pos = skip_space(text, pos + 1)
  elseif text:byte(pos) == BYTE_COMMA then
    pos = skip_space(text, pos + 1)
  end
  if text:byte(pos) == BYTE_CLOSE_BRACKET then
    err = array_end(text, pos)

    return entries, err and pos + 1, err
  end

  for index = first_index, first_index + count - 1 do
    entry, after = nil, nil
    if format == "loki" then
      after = pages.element_end(text, pos) - 1
      while after > pos and text:find("^%s", after) do
        after = after - 1
      end
      entry, decoded = fast_loki_entry(text:sub(pos, after), index)
      after = after + 1
    end
    if not entry then
      node, after = json.parse(text, pos)
      if not node then
        return entries, pos, after
      end
      entry, decoded = element_entry(node, text, index, format)
    end
    entries[#entries + 1] = entry
    if on_json then
      on_json(entry, decoded)
    end

    pos = skip_space(text, after)
    if text:byte(pos) == BYTE_CLOSE_BRACKET then
      err = array_end(text, pos)

      return entries, err and pos + 1, err
    end
    if text:byte(pos) ~= BYTE_COMMA then
      return entries, pos, pos > #text and "unexpected end of input" or string.format("expected , or ] at %d", pos)
    end
    if index < first_index + count - 1 then
      pos = skip_space(text, pos + 1)
    end
  end

  return entries, pos
end

---Order of a loki export by the timestamps of 16 evenly spaced elements and the last one.
---@param text string
---@param format JLogFormat
---@return "asc"|"desc"|"none"
M.element_order = function(text, format)
  local stamps = {}
  local rising, falling

  if format ~= "loki" then
    return "none"
  end
  for sample = 0, 15 do
    stamps[#stamps + 1] = select(3, text:find(TIMESTAMP_PATTERN, math.floor(#text * sample / 16) + 1))
  end
  stamps[#stamps + 1] = last_timestamp(text)
  for index = 2, #stamps do
    rising = rising or ts_less(stamps[index - 1], stamps[index])
    falling = falling or ts_less(stamps[index], stamps[index - 1])
  end
  if rising and falling then
    return "none"
  end

  return falling and "desc" or "asc"
end

---Append each non-blank line of `text` as a plain entry of its own, numbered after the last entry.
---@param entries JLogEntry[] mutated
---@param text string
M.append_plain = function(entries, text)
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    line = line:gsub("\r$", "")
    if line:find("%S") then
      entries[#entries + 1] = { src = #entries + 1, raw = line, body = line }
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
