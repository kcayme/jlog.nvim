---@class JLogItem
---@field kind "entry"|"header"
---@field idx integer|nil entry index
---@field group JLogGroup|nil

---@class JLogGroupArgs
---@field pred fun(i: integer): boolean
---@field field string|nil
---@field get fun(i: integer, path: string): any
---@field reverse boolean|nil

local M = {}

local SUMMARY_FIELDS = { "status", "method", "path" }

local function key_of(value)
  if type(value) == "table" then
    return vim.json.encode(value)
  end

  return tostring(value)
end

-- Last non-nil value wins: a request's final status beats an earlier log line's.
local function summarize(group, get)
  local idxs = group.idxs
  local pending = #SUMMARY_FIELDS
  local index = #idxs

  while index >= 1 and pending > 0 do
    for _, name in ipairs(SUMMARY_FIELDS) do
      if group[name] == nil then
        group[name] = get(idxs[index], name)
        if group[name] ~= nil then
          pending = pending - 1
        end
      end
    end
    index = index - 1
  end
end

local function build_flat(count, args)
  local items = {}
  local size = 0
  local first, last, step = 1, count, 1

  if args.reverse then
    first, last, step = count, 1, -1
  end

  for i = first, last, step do
    if args.pred(i) then
      size = size + 1
      items[size] = { kind = "entry", idx = i }
    end
  end

  return items, size
end

local function build_grouped(count, args)
  local field = args.field
  local items = {}
  local size = 0
  local shown = 0
  local buckets = {}
  local ordered = {}
  local matched = {}
  local missing
  local first, last, step

  for i = 1, count do
    local value = args.get(i, field)
    local bucket

    if value == nil then
      if not missing then
        missing = { label = "(no " .. field .. ")", idxs = {} }
      end
      bucket = missing
    else
      local key = key_of(value)

      bucket = buckets[key]
      if not bucket then
        bucket = { label = key, idxs = {} }
        buckets[key] = bucket
        ordered[#ordered + 1] = bucket
      end
    end

    bucket.idxs[#bucket.idxs + 1] = i
    if not matched[bucket] and args.pred(i) then
      matched[bucket] = true
    end
  end

  if missing then
    ordered[#ordered + 1] = missing
  end

  first, last, step = 1, #ordered, 1
  if args.reverse then
    first, last, step = #ordered, 1, -1
  end

  for position = first, last, step do
    local group = ordered[position]

    if matched[group] then
      local idxs = group.idxs
      local from, to, direction = 1, #idxs, 1

      summarize(group, args.get)
      size = size + 1
      items[size] = { kind = "header", group = group }

      if args.reverse then
        from, to, direction = #idxs, 1, -1
      end
      for index = from, to, direction do
        size = size + 1
        items[size] = { kind = "entry", idx = idxs[index] }
      end
      shown = shown + #idxs
    end
  end

  return items, shown
end

---@param count integer
---@param args JLogGroupArgs
---@return JLogItem[] items
---@return integer shown number of entries shown
M.build = function(count, args)
  if args.field then
    return build_grouped(count, args)
  end

  return build_flat(count, args)
end

return M
