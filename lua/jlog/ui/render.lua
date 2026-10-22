local entry_model = require("jlog.parse.entry")

---0-based start col, exclusive end col, highlight group.
---@alias JLogSpan {[1]: integer, [2]: integer, [3]: string}

---@class JLogGroup
---@field label string value as text, or `"(no <field>)"`
---@field idxs integer[]
---@field status any
---@field method any
---@field path any

local M = {}

local str_find, str_format, str_gsub, str_lower, str_match, str_rep, str_sub, str_upper =
  string.find, string.format, string.gsub, string.lower, string.match, string.rep, string.sub, string.upper
local concat = table.concat

local NEWLINE_ESCAPES = { ["\n"] = "\\n", ["\r"] = "\\r" }
local JSON_ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local LEVEL_GROUPS = {
  error = "JLogLevelError",
  fatal = "JLogLevelError",
  panic = "JLogLevelError",
  warn = "JLogLevelWarn",
  warning = "JLogLevelWarn",
  info = "JLogLevelInfo",
  debug = "JLogLevelDebug",
}
local VALUE_GROUPS = { string = "JLogString", number = "JLogNumber", boolean = "JLogBoolean", null = "JLogNull" }
local COLLAPSED = { object = "{…}", array = "[…]" }

---@class JLogLineBuilder
---@field parts string[]
---@field count integer
---@field col integer
---@field spans JLogSpan[]
---@field sep string|nil separator owed before the next compact item

---@return JLogLineBuilder
local function new_line()
  return { parts = {}, count = 0, col = 0, spans = {} }
end

---@param line JLogLineBuilder
---@param text string
---@param group string|nil
local function push(line, text, group)
  local next_col = line.col + #text

  line.count = line.count + 1
  line.parts[line.count] = text
  if group and next_col > line.col then
    line.spans[#line.spans + 1] = { line.col, next_col, group }
  end
  line.col = next_col
end

---@param line JLogLineBuilder
---@param lines string[]
---@param spans JLogSpan[][]
local function finish(line, lines, spans)
  lines[#lines + 1] = concat(line.parts, "", 1, line.count)
  spans[#spans + 1] = line.spans
end

---@param text string
---@return string
local function escape_newlines(text)
  -- plain finds: LuaJIT compiles them, pattern finds abort the trace on this hot path
  if not str_find(text, "\n", 1, true) and not str_find(text, "\r", 1, true) then
    return text
  end

  return (str_gsub(text, "[\r\n]", NEWLINE_ESCAPES))
end

---@param text string
---@return string
local function quote(text)
  return '"'
    .. str_gsub(text, '[%c"\\]', function(char)
      return JSON_ESCAPES[char] or str_format("\\u%04x", char:byte())
    end)
    .. '"'
end

---@param level string
---@return string
local function level_group(level)
  return LEVEL_GROUPS[str_lower(level)] or "JLogLevelTrace"
end

---@param text string
---@param lines string[]
---@param spans JLogSpan[][]
local function push_plain(text, lines, spans)
  for _, part in ipairs(vim.split(text, "\n", { plain = true })) do
    lines[#lines + 1] = part
    spans[#spans + 1] = { { 0, #part, "JLogPlain" } }
  end
end

---@param entry JLogEntry
---@param lines string[]
---@param spans JLogSpan[][]
local function push_continuations(entry, lines, spans)
  for _, cont in ipairs(entry.cont or {}) do
    lines[#lines + 1] = cont
    spans[#spans + 1] = { { 0, #cont, "JLogPlain" } }
  end
end

-- weak cache: alias -> { role, rank } per `opts.fields` table
local alias_cache = setmetatable({}, { __mode = "k" })

---@param fields JLogFieldsOptions
---@return table<string, {[1]: string, [2]: integer}>
local function aliases_of(fields)
  local aliases = alias_cache[fields]

  if aliases then
    return aliases
  end
  aliases = {}
  for _, role in ipairs({ "time", "level", "message" }) do
    for rank, alias in ipairs(fields[role]) do
      aliases[alias] = aliases[alias] or { role, rank }
    end
  end
  alias_cache[fields] = aliases

  return aliases
end

---Indexes of the time/level/message fields: per role, the scalar field whose alias is configured first.
---@param node JLogNode
---@param fields JLogFieldsOptions
---@return table<string, integer>
local function find_fields(node, fields)
  local aliases = aliases_of(fields)
  local keys, vals = node.keys, node.vals
  local found, ranks = {}, {}
  local alias

  for index = 1, #keys do
    alias = aliases[keys[index]]
    if alias and vals[index].lit and (not ranks[alias[1]] or alias[2] < ranks[alias[1]]) then
      found[alias[1]] = index
      ranks[alias[1]] = alias[2]
    end
  end

  return found
end

---@param node JLogNode
---@return string
local function scalar_text(node)
  return node.str or node.lit
end

---@param value string
---@return string
local function short_time(value)
  local clock, fraction = str_match(value, "T(%d%d:%d%d:%d%d)%.?(%d*)")

  if not clock then
    return value
  end

  return clock .. "." .. str_sub(fraction .. "000", 1, 3)
end

---UTC `HH:MM:SS.mmm` from a nanosecond epoch string, sliced to avoid float precision loss.
---@param ts string
---@return string
local function loki_time(ts)
  local padded = str_rep("0", 10 - #ts) .. ts

  if not str_find(ts, "^%d+$") then
    return ts
  end

  return os.date("!%H:%M:%S", tonumber(str_sub(padded, 1, -10))) .. "." .. str_sub(padded, -9, -7)
end

---Append `text`, preceded by the separator owed by the previous item.
---@param line JLogLineBuilder
---@param text string
---@param group string
local function push_item(line, text, group)
  if line.sep then
    push(line, line.sep)
  end
  push(line, text, group)
  line.sep = " "
end

---@param line JLogLineBuilder
---@param key string
---@param value string
local function push_field(line, key, value)
  local col

  if line.sep then
    push(line, line.sep)
  end
  col = line.col
  push(line, key)
  push(line, "=")
  line.spans[#line.spans + 1] = { col, line.col, "JLogKey" }
  push(line, value, "JLogValue")
  line.sep = " "
end

local push_fields

---@param line JLogLineBuilder
---@param key string dotted path
---@param node JLogNode
---@param text string text the node's offsets refer to
---@param base integer byte offset of `text` position 1 minus one
local function push_value(line, key, node, text, base)
  local inner = node.inner

  if node.t == "object" and #node.keys > 0 then
    push_fields(line, key .. ".", node, text, base)
  elseif node.t == "object" or node.t == "array" then
    push_field(line, key, escape_newlines(str_sub(text, base + node.s, base + node.e)))
  elseif inner and node.prefix ~= "" then
    push_field(line, key, escape_newlines(node.prefix) .. COLLAPSED[inner.t])
  elseif inner then
    push_value(line, key, inner, node.str, 0)
  else
    push_field(line, key, escape_newlines(scalar_text(node)))
  end
end

---@param line JLogLineBuilder
---@param key_prefix string
---@param node JLogNode object
---@param text string
---@param base integer
---@param skip table<integer, boolean>|nil indexes already shown
push_fields = function(line, key_prefix, node, text, base, skip)
  local keys, vals = node.keys, node.vals

  for index = 1, #keys do
    if not (skip and skip[index]) then
      push_value(line, key_prefix == "" and keys[index] or key_prefix .. keys[index], vals[index], text, base)
    end
  end
end

---@param entry JLogEntry
---@param node JLogNode
---@param prefix string
---@param opts JLogOptions
---@param lines string[]
---@param spans JLogSpan[][]
local function compact_json(entry, node, prefix, opts, lines, spans)
  local line = new_line()
  local found = find_fields(node, opts.fields)
  local time_index, level_index, message_index = found.time, found.level, found.message
  local skip = {}
  local shown = 0
  local level

  prefix = str_match(prefix, "^(.-)%s*$")
  if prefix ~= "" then
    push_item(line, escape_newlines(prefix), "JLogPrefix")
  end
  if time_index then
    skip[time_index] = true
    shown = shown + 1
    push_item(line, short_time(scalar_text(node.vals[time_index])), "JLogTime")
  elseif entry.ts and entry.ts ~= "" then
    push_item(line, loki_time(entry.ts), "JLogTime")
  end
  if level_index then
    skip[level_index] = true
    shown = shown + 1
    level = scalar_text(node.vals[level_index])
    push_item(line, str_upper(level), level_group(level))
    line.sep = str_rep(" ", math.max(1, 6 - #level))
  end
  if message_index then
    skip[message_index] = true
    shown = shown + 1
    push_item(line, escape_newlines(scalar_text(node.vals[message_index])), "JLogMessage")
  end

  if line.sep and #node.keys > shown then
    line.sep = #line.sep >= 2 and line.sep or "  "
  end
  push_fields(line, "", node, entry.body, entry.json_at - 1, skip)
  finish(line, lines, spans)
end

local push_expanded

---@param keys string[]|nil nil for arrays
---@param vals JLogNode[]
---@param indent string
---@param open_line JLogLineBuilder already holds the indent/key/prefix
---@param close string
---@param comma string
---@param lines string[]
---@param spans JLogSpan[][]
local function push_container(keys, vals, indent, open_line, close, comma, lines, spans)
  local child_indent = indent .. "  "

  if #vals == 0 then
    push(open_line, (keys and "{" or "[") .. close .. comma)
    finish(open_line, lines, spans)

    return
  end

  push(open_line, keys and "{" or "[")
  finish(open_line, lines, spans)
  for index, value in ipairs(vals) do
    push_expanded(keys and keys[index], value, child_indent, index < #vals and "," or "", lines, spans)
  end
  lines[#lines + 1] = indent .. close .. comma
  spans[#spans + 1] = {}
end

---@param key string|nil
---@param node JLogNode
---@param indent string
---@param comma string
---@param lines string[]
---@param spans JLogSpan[][]
push_expanded = function(key, node, indent, comma, lines, spans)
  local line = new_line()
  local target = node.inner or node

  push(line, indent)
  if key then
    push(line, quote(key), "JLogKey")
    push(line, ": ")
  end
  if node.inner and node.prefix ~= "" then
    push(line, quote(node.prefix), "JLogPrefix")
    push(line, " ")
  end

  if target.t == "object" then
    push_container(target.keys, target.vals, indent, line, "}", comma, lines, spans)
  elseif target.t == "array" then
    push_container(nil, target.vals, indent, line, "]", comma, lines, spans)
  else
    push(line, escape_newlines(target.lit), VALUE_GROUPS[target.t])
    push(line, comma)
    finish(line, lines, spans)
  end
end

---@param entry JLogEntry
---@return string[] keys
---@return JLogNode[] vals
local function labels_object(entry)
  local keys = vim.tbl_keys(entry.labels)
  local vals = {}

  table.sort(keys)
  for index, key in ipairs(keys) do
    vals[index] = { t = "string", lit = quote(entry.labels[key]) }
  end

  return keys, vals
end

---One line per entry (plus continuation lines).
---@param entry JLogEntry
---@param opts JLogOptions
---@return string[] lines
---@return JLogSpan[][] spans per line
M.compact = function(entry, opts)
  local lines, spans = {}, {}
  local node, prefix = entry_model.tree(entry, opts)

  if not node or node.t ~= "object" then
    push_plain(entry.body, lines, spans)
    push_continuations(entry, lines, spans)

    return lines, spans
  end

  compact_json(entry, node, prefix, opts, lines, spans)
  push_continuations(entry, lines, spans)

  return lines, spans
end

---Indented JSON in source key order, unwrapped values nested, labels appended.
---@param entry JLogEntry
---@param opts JLogOptions
---@return string[] lines
---@return JLogSpan[][] spans per line
M.expanded = function(entry, opts)
  local lines, spans = {}, {}
  local node, prefix = entry_model.tree(entry, opts)
  local open_line = new_line()
  local keys, vals, label_keys, label_vals

  if not node or node.t ~= "object" then
    push_plain(entry.body, lines, spans)
    push_continuations(entry, lines, spans)

    return lines, spans
  end

  keys, vals = node.keys, node.vals
  if entry.labels and next(entry.labels) then
    label_keys, label_vals = labels_object(entry)
    keys, vals = vim.list_extend({}, keys), vim.list_extend({}, vals)
    keys[#keys + 1] = "labels"
    vals[#vals + 1] = { t = "object", keys = label_keys, vals = label_vals }
  end

  prefix = str_match(prefix, "^(.-)%s*$")
  if prefix ~= "" then
    push(open_line, escape_newlines(prefix), "JLogPrefix")
    push(open_line, " ")
  end
  push_container(keys, vals, "", open_line, "}", "", lines, spans)
  push_continuations(entry, lines, spans)

  return lines, spans
end

---`▾ <label>  <n> entries · <status> · <method> <path>`; nil parts are omitted.
---@param group JLogGroup
---@return string line
---@return JLogSpan[] spans
M.header = function(group)
  local label = group.label
  local count = #group.idxs
  local parts = {}
  local request = {}
  local line

  if vim.fn.strchars(label) > 8 then
    label = vim.fn.strcharpart(label, 0, 8) .. "…"
  end
  parts[1] = "▾ " .. label .. "  " .. count .. (count == 1 and " entry" or " entries")
  if group.status ~= nil then
    parts[#parts + 1] = tostring(group.status)
  end
  if group.method ~= nil then
    request[#request + 1] = tostring(group.method)
  end
  if group.path ~= nil then
    request[#request + 1] = tostring(group.path)
  end
  if #request > 0 then
    parts[#parts + 1] = concat(request, " ")
  end
  line = concat(parts, " · ")

  return line, { { 0, #line, "JLogGroupHeader" } }
end

return M
