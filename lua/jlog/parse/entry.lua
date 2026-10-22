local json = require("jlog.parse.json")

local M = {}

local ALIAS_FIELDS = { time = "time", level = "level", msg = "message" }

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

---@param prefix string
---@param value table
---@param out table<string, any>
local function flatten_into(prefix, value, out)
  for key, child in pairs(value) do
    if type(child) == "table" and not vim.islist(child) then
      flatten_into(prefix .. key .. ".", child, out)
    elseif type(child) ~= "table" and child ~= vim.NIL then
      out[prefix .. key] = child
    end
  end
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
  local segments = vim.split(path, ".", { plain = true })
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
      current = unwrap_string(current)
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

---Dotted path to scalar for every field, including labels. Arrays and nulls are skipped.
---@param entry JLogEntry
---@param decoded table|nil
---@return table<string, any>
M.flatten = function(entry, decoded)
  local out = {}

  if decoded then
    flatten_into("", decoded, out)
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
