local entry_model = require("jlog.parse.entry")

local M = {}

---@class JLogTerm
---@field neg boolean
---@field field string|nil
---@field op "="|"!="|">"|">="|"<"|"<="|"~"|nil
---@field value string
---@field re any|nil compiled vim.regex for `~` and bare terms
---@field num number|nil numeric form of `value`, when it is one
---@field lower string|nil lowercased `value`, for the case-insensitive `level` field

---@class JLogMatchCtx
---@field get fun(path: string): any
---@field raw string entry raw text plus continuation lines

local TWO_CHAR_OPS = { ["!="] = true, [">="] = true, ["<="] = true }

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
  field = text:sub(1, op_start - 1)

  return neg, field, op, text:sub(op_start + #op)
end

-- Reads one whitespace-delimited term starting at `pos`; a double-quoted value may contain spaces, \", \\ and
-- \n (a newline).
-- Returns term, is_or, next_pos or nil, err.
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
    if prefix == "OR" then
      return nil, true, stop
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
    -- intentionally honors the user's 'ignorecase' (spec §7: same flavor as `/`); no \C
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

  return nil
end

---@param line string
---@return JLogTerm[][]|nil, string|nil
M.parse = function(line)
  local alternatives = { {} }
  local pos = 1
  local term
  local is_or
  local err
  local current

  while true do
    pos = line:find("%S", pos)
    if not pos then
      break
    end

    term, is_or, pos, err = read_term(line, pos)
    if err then
      return nil, err
    end

    current = alternatives[#alternatives]
    if is_or then
      if #current == 0 then
        return nil, "empty alternative before OR"
      end
      alternatives[#alternatives + 1] = {}
    else
      err = finish_term(term)
      if err then
        return nil, err
      end
      current[#current + 1] = term
    end
  end

  if #alternatives[#alternatives] == 0 then
    return nil, "empty alternative"
  end

  return alternatives, nil
end

local function matches_term(term, ctx)
  local op = term.op
  local value
  local text
  local number
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

  number = tonumber(value)
  if not number or not term.num then
    return false
  end
  if op == ">" then
    return number > term.num
  elseif op == ">=" then
    return number >= term.num
  elseif op == "<" then
    return number < term.num
  end

  return number <= term.num
end

local function matches_alternative(alternative, ctx)
  for _, term in ipairs(alternative) do
    if matches_term(term, ctx) == term.neg then
      return false
    end
  end

  return true
end

---@param lines string[]
---@return fun(ctx: JLogMatchCtx): boolean
---@return {lnum: integer, msg: string}[]
M.compile = function(lines)
  local parsed = {}
  local errors = {}
  local alternatives
  local err

  for lnum, line in ipairs(lines) do
    if line:match("%S") then
      alternatives, err = M.parse(line)
      if err then
        errors[#errors + 1] = { lnum = lnum, msg = err }
      else
        parsed[#parsed + 1] = alternatives
      end
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

return M
