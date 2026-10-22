---@class JLogFacet
---@field name string
---@field distinct integer
---@field capped boolean
---@field top {value: string, count: integer}[]

local M = {}

local MAX_DISTINCT = 1000

local function is_label(name)
  return name:sub(1, 7) == "labels."
end

local function sort_names(left, right)
  local left_label, right_label = is_label(left), is_label(right)

  if left_label ~= right_label then
    return right_label
  end

  return left < right
end

local function by_count(left, right)
  if left.count ~= right.count then
    return left.count > right.count
  end

  return left.value < right.value
end

---@param idxs integer[]
---@param flat fun(i: integer): table<string, any>
---@param top_n integer
---@return JLogFacet[]
M.count = function(idxs, flat, top_n)
  local fields = {}
  local names = {}
  local facets = {}

  for _, idx in ipairs(idxs) do
    for name, value in pairs(flat(idx)) do
      local field = fields[name]
      local text = tostring(value)

      if not field then
        field = { counts = {}, distinct = 0, capped = false }
        fields[name] = field
        names[#names + 1] = name
      end

      if field.counts[text] then
        field.counts[text] = field.counts[text] + 1
      elseif field.distinct < MAX_DISTINCT then
        field.counts[text] = 1
        field.distinct = field.distinct + 1
      else
        field.capped = true
      end
    end
  end

  table.sort(names, sort_names)

  for _, name in ipairs(names) do
    local field = fields[name]
    local top = {}

    for value, count in pairs(field.counts) do
      top[#top + 1] = { value = value, count = count }
    end
    table.sort(top, by_count)
    for index = top_n + 1, #top do
      top[index] = nil
    end

    facets[#facets + 1] = { name = name, distinct = field.distinct, capped = field.capped, top = top }
  end

  return facets
end

return M
