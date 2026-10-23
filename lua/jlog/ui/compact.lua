local M = {}

---@class JLogCompactResolved
---@field active boolean
---@field style JLogFieldStyle
---@field fields table<string, JLogCompactField>
---@field rank_of table<string, integer>
---@field order string[]
---@field status table<string, boolean>
---@field failed table<string, boolean> keys whose format already warned

-- weak cache: resolution per `opts` table
local resolve_cache = setmetatable({}, { __mode = "k" })

-- one context table refilled per format call
local format_ctx = {}

---@param resolved JLogCompactResolved
---@param key string
---@param err any
local function warn_once(resolved, key, err)
  if resolved.failed[key] then
    return
  end
  resolved.failed[key] = true
  vim.notify(("jlog: format for %s failed: %s"):format(key, tostring(err)), vim.log.levels.WARN)
end

---@param opts JLogOptions
---@return JLogCompactResolved
M.resolve = function(opts)
  local resolved = resolve_cache[opts]
  local compact, rank_of, status

  if resolved then
    return resolved
  end
  compact = opts.compact
  rank_of, status = {}, {}
  for rank, key in ipairs(compact.order) do
    rank_of[key] = rank_of[key] or rank
  end
  for _, alias in ipairs(opts.fields.status) do
    status[alias] = true
  end
  resolved = {
    active = compact.style ~= "plain" or #compact.order > 0 or next(compact.fields) ~= nil,
    style = compact.style,
    fields = compact.fields,
    rank_of = rank_of,
    order = compact.order,
    status = status,
    failed = {},
  }
  resolve_cache[opts] = resolved

  return resolved
end

---@param resolved JLogCompactResolved
---@param key string
---@param role "time"|"level"|"message"|"status"|nil
---@return JLogFieldStyle
M.style_of = function(resolved, key, role)
  local by_key = resolved.fields[key]
  local by_role = role and resolved.fields[role]

  if by_key and by_key.style then
    return by_key.style
  end
  if by_role and by_role.style then
    return by_role.style
  end
  if role == "time" or role == "message" then
    return "plain"
  end
  if role == "level" and resolved.style == "plain" then
    return "inverted"
  end

  return resolved.style
end

---@param resolved JLogCompactResolved
---@param key string
---@param role "time"|"level"|"message"|"status"|nil
---@param value string
---@param entry JLogEntry
---@return string|nil text
---@return string|nil highlight
M.format = function(resolved, key, role, value, entry)
  local by_key = resolved.fields[key]
  local by_role = role and resolved.fields[role]
  local format = (by_key and by_key.format) or (by_role and by_role.format)
  local ok, text, highlight

  if not format then
    return nil
  end
  format_ctx.value, format_ctx.key, format_ctx.entry = value, key, entry
  ok, text, highlight = pcall(format, format_ctx)
  if not ok then
    warn_once(resolved, key, text)

    return nil
  end
  if type(text) ~= "string" then
    warn_once(resolved, key, "expected a string, got " .. type(text))

    return nil
  end

  return text, highlight
end

---@param value string
---@return string|nil
M.status_group = function(value)
  local first = value:match("^([2-5])%d%d$")

  return first and ("JLogStatus%sxx"):format(first) or nil
end

return M
