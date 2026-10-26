-- Groups entries by a field's value into headers and items.

---@class JLogItem
---@field kind "entry"|"header"
---@field idx integer|nil entry index
---@field group JLogGroup|nil

---@class JLogGroupArgs
---@field pred fun(i: integer): boolean
---@field field string|nil
---@field get fun(i: integer, path: string): any
---@field reverse boolean|nil show the stored order reversed
---@field newest_first boolean|nil entries are stored newest first; groups are still built in time order
---@field checkpoint fun()|nil called every CHECKPOINT_EVERY entries, so a caller can yield a long build
---@field limit integer|nil show at most this many entries, the first in display order
---@field group_limit integer|nil show at most this many groups, the first in display order

local entry_model = require("jlog.parse.entry")

local M = {}

local CHECKPOINT_EVERY = 4096

local function key_of(value)
  if type(value) == "table" then
    return vim.json.encode(value)
  end

  return entry_model.text(value)
end

local function build_flat(count, args)
  local items = {}
  local size = 0
  local first, last, step = 1, count, 1

  if args.reverse then
    first, last, step = count, 1, -1
  end

  for i = first, last, step do
    if args.checkpoint and i % CHECKPOINT_EVERY == 0 then
      args.checkpoint()
    end
    if args.pred(i) then
      size = size + 1
      items[size] = { kind = "entry", idx = i }
      if size == args.limit then
        break
      end
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
  local groups = 0
  local first, last, step
  -- groups and their entries are collected oldest first, then shown newest first when that is on top
  local newest_on_top = (args.reverse or false) ~= (args.newest_first or false)

  first, last, step = 1, count, 1
  if args.newest_first then
    first, last, step = count, 1, -1
  end

  for i = first, last, step do
    local value = args.get(i, field)
    local bucket

    if args.checkpoint and i % CHECKPOINT_EVERY == 0 then
      args.checkpoint()
    end
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

  -- the missing group goes last in either order: on top it would span the page and defeat line reuse
  if newest_on_top then
    for position = 1, math.floor(#ordered / 2) do
      ordered[position], ordered[#ordered + 1 - position] = ordered[#ordered + 1 - position], ordered[position]
    end
  end
  if missing then
    ordered[#ordered + 1] = missing
  end

  for _, group in ipairs(ordered) do
    if groups == args.group_limit or shown == args.limit then
      break
    end
    if matched[group] then
      local idxs = group.idxs
      local from, to, direction = 1, #idxs, 1

      groups = groups + 1
      size = size + 1
      items[size] = { kind = "header", group = group }

      if newest_on_top then
        from, to, direction = #idxs, 1, -1
      end
      for index = from, to, direction do
        size = size + 1
        shown = shown + 1
        items[size] = { kind = "entry", idx = idxs[index] }
        if args.checkpoint and size % CHECKPOINT_EVERY == 0 then
          args.checkpoint()
        end
        -- the total cap can cut the last group short
        if shown == args.limit then
          break
        end
      end
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
