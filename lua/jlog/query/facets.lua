local entry_model = require("jlog.parse.entry")

---@class JLogFacet
---@field name string
---@field distinct integer
---@field capped boolean
---@field estimated boolean counts may be low because values were dropped by a capped merge
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

---@class JLogFacetCounter
---@field fields table<string, {counts: table<string, integer>, distinct: integer, capped: boolean, estimated: boolean|nil}>
---@field names string[]

---Incremental counting, so a caller can feed flattened entries as it produces them.
---@return JLogFacetCounter
M.counter = function()
  return { fields = {}, names = {} }
end

---@param counter JLogFacetCounter
---@param flat table<string, any>
M.add = function(counter, flat)
  local fields, names = counter.fields, counter.names

  for name, value in pairs(flat) do
    local field = fields[name]
    local text = entry_model.text(value)

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

---Adds another counter's fields into `counter`, keeping at most MAX_DISTINCT values per field.
---@param counter JLogFacetCounter
---@param fields table<string, {counts: table<string, integer>, distinct: integer, capped: boolean}>
M.merge = function(counter, fields)
  local field
  local dropped

  for name, incoming in pairs(fields) do
    field = counter.fields[name]
    dropped = false

    if not field then
      field = { counts = {}, distinct = 0, capped = false }
      counter.fields[name] = field
      counter.names[#counter.names + 1] = name
    end

    for value, count in pairs(incoming.counts) do
      if field.counts[value] then
        field.counts[value] = field.counts[value] + count
      elseif field.distinct < MAX_DISTINCT then
        field.counts[value] = count
        field.distinct = field.distinct + 1
      else
        dropped = true
      end
    end

    if dropped or incoming.capped or field.capped then
      field.estimated = true
    end
    field.capped = field.capped or incoming.capped or dropped
  end
end

---@param counter JLogFacetCounter
---@param top_n integer
---@return JLogFacet[]
M.result = function(counter, top_n)
  local names = counter.names
  local facets = {}

  table.sort(names, sort_names)

  for _, name in ipairs(names) do
    local field = counter.fields[name]
    local top = {}

    for value, count in pairs(field.counts) do
      top[#top + 1] = { value = value, count = count }
    end
    table.sort(top, by_count)
    for index = top_n + 1, #top do
      top[index] = nil
    end

    facets[#facets + 1] = {
      name = name,
      distinct = field.distinct,
      capped = field.capped,
      estimated = field.estimated == true,
      top = top,
    }
  end

  return facets
end

---@param idxs integer[]
---@param flat fun(i: integer): table<string, any>
---@param top_n integer
---@return JLogFacet[]
M.count = function(idxs, flat, top_n)
  local counter = M.counter()

  for _, idx in ipairs(idxs) do
    M.add(counter, flat(idx))
  end

  return M.result(counter, top_n)
end

return M
