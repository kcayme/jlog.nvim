local config = require("jlog.config")
local entry_model = require("jlog.parse.entry")
local time = require("jlog.parse.time")

local M = {}

---@class JLogTerm
---@field neg boolean
---@field field string|nil
---@field op "="|"!="|">"|">="|"<"|"<="|"~"|nil
---@field value string
---@field re any|nil compiled vim.regex for `~` and bare terms
---@field num number|nil numeric form of `value`, when it is one
---@field epoch number|nil `value` as seconds since the epoch, for `>`, `>=`, `<`, `<=` on a typed time
---@field lower string|nil lowercased `value`, for the case-insensitive `level` field

---@class JLogMatchCtx
---@field get fun(path: string): any
---@field raw string entry raw text plus continuation lines

local TWO_CHAR_OPS = { ["!="] = true, [">="] = true, ["<="] = true }
local ORDER_OPS = { [">"] = true, [">="] = true, ["<"] = true, ["<="] = true }
local FIELD_ESCAPES = { n = "\n", ["\\"] = "\\" }

-- Field names are written with `\n` for a newline and `\\` for a backslash, so they fit on one line.
local function escape_field(name)
  return (name:gsub("\\", "\\\\"):gsub("\n", "\\n"))
end

local function unescape_field(text)
  return (text:gsub("\\(.)", FIELD_ESCAPES))
end

-- Splits an unquoted token like `-status>=500` into neg, field, op, value. Bare terms have no field/op.
local function split_token(text)
  local neg = false
  local op_start
  local op
  local field

  if #text > 1 and text:sub(1, 1) == "-" then
    neg = true
    text = text:sub(2)
  end

  op_start = text:find("[=!<>~]")
  if not op_start or op_start == 1 then
    return neg, nil, nil, text
  end

  op = text:sub(op_start, op_start + 1)
  if not TWO_CHAR_OPS[op] then
    op = text:sub(op_start, op_start)
  end
  if op == "!" then
    return neg, nil, nil, text
  end
  field = unescape_field(text:sub(1, op_start - 1))

  return neg, field, op, text:sub(op_start + #op)
end

-- Reads one term at `pos` (quoted values allow spaces, \", \\ and \n); returns term, keyword, next_pos or nil, err.
local function read_term(line, pos)
  local stop = line:find('[%s"]', pos) or #line + 1
  local prefix = line:sub(pos, stop - 1)
  local neg
  local field
  local op
  local value
  local chars = {}
  local idx
  local char

  if line:sub(stop, stop) ~= '"' then
    if prefix == "OR" or prefix == "AND" then
      return nil, prefix, stop
    end
    neg, field, op, value = split_token(prefix)

    return { neg = neg, field = field, op = op, value = value }, false, stop
  end

  neg, field, op, value = split_token(prefix)
  if value ~= "" then
    return nil, false, nil, "unexpected quote in `" .. prefix .. "`"
  end

  idx = stop + 1
  while idx <= #line do
    char = line:sub(idx, idx)
    if char == "\\" and (line:sub(idx + 1, idx + 1) == '"' or line:sub(idx + 1, idx + 1) == "\\") then
      chars[#chars + 1] = line:sub(idx + 1, idx + 1)
      idx = idx + 2
    elseif char == "\\" and line:sub(idx + 1, idx + 1) == "n" then
      chars[#chars + 1] = "\n"
      idx = idx + 2
    elseif char == '"' then
      return { neg = neg, field = field, op = op, value = table.concat(chars) }, false, idx + 1
    else
      chars[#chars + 1] = char
      idx = idx + 1
    end
  end

  return nil, false, nil, "unterminated quote"
end

local function finish_term(term)
  local ok
  local re

  if term.op == "~" or not term.field then
    -- honors the user's 'ignorecase', like `/` does; no \C
    ok, re = pcall(vim.regex, term.value)
    if not ok then
      return "invalid regex `" .. term.value .. "`"
    end
    term.re = re
  end
  -- integers past 2^53 arrive as their literal text (see entry.get), so `=` on them compares text exactly
  if term.value:match("^-?%d[%d%.eE+-]*$") then
    term.num = tonumber(term.value)
  end
  if term.field == "level" then
    term.lower = term.value:lower()
  end
  if ORDER_OPS[term.op] and not term.num then
    term.epoch = time.parse_input(term.value, config.options.view.time_utc)
  end

  return nil
end

---@param line string
---@return JLogTerm[][]|nil alternatives
---@return string|nil err
---@return integer|nil err_start first byte of the part that failed
---@return integer|nil err_end its last byte
M.parse = function(line)
  local alternatives = { {} }
  local pos = 1
  local term
  local keyword
  local err
  local current
  local start
  local last_or_start, last_or_end

  while true do
    pos = line:find("%S", pos)
    if not pos then
      break
    end

    start = pos
    term, keyword, pos, err = read_term(line, pos)
    if err then
      -- an unterminated quote runs to the end of the line; anything else is its token
      return nil, err, start, err == "unterminated quote" and #line or (line:find("%s", start) or #line + 1) - 1
    end

    current = alternatives[#alternatives]
    if keyword == "OR" then
      if #current == 0 then
        return nil, "empty alternative before OR", start, pos - 1
      end
      alternatives[#alternatives + 1] = {}
      last_or_start, last_or_end = start, pos - 1
    elseif keyword == "AND" then
      -- spelled-out AND is what a space already means
      if #current == 0 then
        return nil, "nothing before AND", start, pos - 1
      end
    else
      err = finish_term(term)
      if err then
        return nil, err, start, pos - 1
      end
      current[#current + 1] = term
    end
  end

  if #alternatives[#alternatives] == 0 then
    return nil, "empty alternative", last_or_start or 1, last_or_end or #line
  end

  return alternatives, nil
end

local function matches_term(term, ctx)
  local op = term.op
  local value
  local text
  local number, term_number
  local seconds, fraction
  local equal

  if not op then
    return term.re:match_str(ctx.raw) ~= nil
  end

  value = ctx.get(term.field)
  if value == nil then
    return false
  end

  if op == "~" then
    text = type(value) == "table" and vim.json.encode(value) or entry_model.text(value)

    return term.re:match_str(text) ~= nil
  end

  if op == "=" or op == "!=" then
    -- a present table never equals a scalar
    if type(value) == "table" then
      equal = false
    elseif type(value) == "number" and term.num then
      equal = value == term.num
    elseif term.lower then
      equal = entry_model.text(value):lower() == term.lower
    else
      equal = entry_model.text(value) == term.value
      if not equal and term.num then
        equal = tonumber(value) == term.num
      end
    end

    return equal == (op == "=")
  end

  if type(value) == "table" then
    return false
  end

  if term.epoch then
    seconds, fraction = time.parse_iso(entry_model.text(value))
    number = seconds and seconds + (fraction ~= "" and tonumber("0." .. fraction) or 0)
    if not number then
      return false
    end
    term_number = term.epoch
  else
    number, term_number = tonumber(value), term.num
  end
  if not number or not term_number then
    return false
  end
  if op == ">" then
    return number > term_number
  elseif op == ">=" then
    return number >= term_number
  elseif op == "<" then
    return number < term_number
  end

  return number <= term_number
end

local function matches_alternative(alternative, ctx)
  for _, term in ipairs(alternative) do
    if matches_term(term, ctx) == term.neg then
      return false
    end
  end

  return true
end

---A filter line's leading `AND` or `OR`, the text after it, and the bytes the prefix takes; no prefix gives nil.
---@param line string
---@return "AND"|"OR"|nil keyword
---@return string rest
---@return integer offset
local function split_prefix(line)
  local offset, rest = line:match("^(%s*AND%s+)(.*)$")

  if offset then
    return "AND", rest, #offset
  end
  offset, rest = line:match("^(%s*OR%s+)(.*)$")
  if offset then
    return "OR", rest, #offset
  end

  return nil, line, 0
end

---Where `line` alone fails to parse, its `AND`/`OR` prefix aside: the message and the 0-based, end-exclusive columns.
---@param line string
---@return string|nil msg nil when the line parses on its own
---@return integer|nil col
---@return integer|nil end_col
M.locate = function(line)
  local _, rest, offset = split_prefix(line)
  local err, err_start, err_end

  _, err, err_start, err_end = M.parse(rest)
  if not err then
    return nil
  end

  return err, offset + err_start - 1, offset + err_end
end

---@class JLogFilterGroup
---@field text string the group's lines as one line, `OR` between them
---@field first integer index of its first line
---@field last integer index of its last line

---Filter lines to the groups they form: an `OR` line continues the group above, an `AND` line or one without a
---prefix starts a new one; groups are ANDed.
---@param lines string[]
---@return JLogFilterGroup[]
M.groups = function(lines)
  local groups = {}
  local keyword, rest, last_group

  for index, line in ipairs(lines) do
    keyword, rest = split_prefix(line)
    last_group = groups[#groups]
    if keyword == "OR" and last_group then
      last_group.text = last_group.text .. " OR " .. rest
      last_group.last = index
    elseif line:match("%S") then
      -- a first line starting with OR stays as written, so the parser reports it
      groups[#groups + 1] = { text = keyword == "AND" and rest or line, first = index, last = index }
    end
  end

  return groups
end

---`lines` with every operator written out: no `AND` on the first line, `AND` on later lines that have none.
---@param lines string[]
---@return string[]
M.explicit = function(lines)
  local out = {}
  local keyword, rest

  for index, line in ipairs(lines) do
    keyword, rest = split_prefix(line)
    if index == 1 then
      out[index] = keyword == "AND" and rest or line
    elseif keyword then
      out[index] = line
    else
      out[index] = "AND " .. line
    end
  end

  return out
end

---@param lines string[]
---@return fun(ctx: JLogMatchCtx): boolean
---@return {lnum: integer, last: integer, msg: string}[] lines `lnum`..`last` form the group that failed
M.compile = function(lines)
  local parsed = {}
  local errors = {}
  local alternatives
  local err

  for _, group in ipairs(M.groups(lines)) do
    alternatives, err = M.parse(group.text)
    if err then
      errors[#errors + 1] = { lnum = group.first, last = group.last, msg = err }
    else
      parsed[#parsed + 1] = alternatives
    end
  end

  if #parsed == 0 then
    return function()
      return true
    end, errors
  end

  return function(ctx)
    for _, line_alternatives in ipairs(parsed) do
      local any = false
      for _, alternative in ipairs(line_alternatives) do
        if matches_alternative(alternative, ctx) then
          any = true
          break
        end
      end
      if not any then
        return false
      end
    end

    return true
  end,
    errors
end

---The field and values of a line made only of `field=value` alternatives on one field, e.g. `status=500 OR status=502`.
---@param line string
---@return string|nil field nil when the line is anything else
---@return string[] values
M.facet_of = function(line)
  local alternatives = M.parse(line)
  local values = {}
  local field, term

  if not alternatives then
    return nil, values
  end
  for _, alternative in ipairs(alternatives) do
    term = alternative[1]
    if #alternative ~= 1 or term.neg or term.op ~= "=" or (field and term.field ~= field) then
      return nil, {}
    end
    field = term.field
    values[#values + 1] = term.value
  end

  return field, values
end

---`field=value`, quoting the value when the parser needs it; a newline is written as `\n`.
---@param name string
---@param value string
---@return string
M.clause = function(name, value)
  name = escape_field(name)
  if value ~= "" and not value:find('[%s"]') then
    return name .. "=" .. value
  end

  return name .. '="' .. value:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
end

---A field name as written in filter and group text.
---@param name string
---@return string
M.escape_field = escape_field

---The field name that filter or group text stands for.
---@param text string
---@return string
M.unescape_field = unescape_field

return M
