-- Counts field values for the sidebar's FIELDS list.
local entry_model = require("jlog.parse.entry")

---@class JLogFacet
---@field name string
---@field distinct integer
---@field capped boolean
---@field estimated boolean counts may be low because values were dropped by a capped merge
---@field present integer entries the field appears in, counted past the distinct cap
---@field label boolean a label of a timestamped export, listed after the other fields
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

---@class JLogFacetField
---@field counts table<string, integer>
---@field distinct integer
---@field present integer entries the field appears in, never capped
---@field capped boolean
---@field estimated boolean|nil

---@class JLogFacetCounter
---@field fields table<string, JLogFacetField>
---@field names string[]
---@field paths table<string, table<string, string>> per parent path, each key's dotted name (`entry.child_path`)

---Incremental counting, so a caller can feed entries as it reads them.
---@return JLogFacetCounter
M.counter = function()
  return { fields = {}, names = {}, paths = {} }
end

---Count one entry's `value` of the field `name`; nil and tables (absent, objects, arrays) are skipped.
---@param counter JLogFacetCounter
---@param name string
---@param value any
M.add_value = function(counter, name, value)
  local field = counter.fields[name]
  local text

  if value == nil or type(value) == "table" then
    return
  end
  text = entry_model.text(value)
  if not field then
    field = { counts = {}, distinct = 0, capped = false, present = 0 }
    counter.fields[name] = field
    counter.names[#counter.names + 1] = name
  end

  field.present = field.present + 1
  if field.counts[text] then
    field.counts[text] = field.counts[text] + 1
  elseif field.distinct < MAX_DISTINCT then
    field.counts[text] = 1
    field.distinct = field.distinct + 1
  else
    field.capped = true
  end
end

---@param counter JLogFacetCounter
---@param flat table<string, any>
M.add = function(counter, flat)
  for name, value in pairs(flat) do
    M.add_value(counter, name, value)
  end
end

---Replace `counter`'s fields with those `other` counted; a missing aliased name is skipped, as it was counted under
---the log's own key (`level=ERROR` on `severity` logs), which `counter` already lists.
---@param counter JLogFacetCounter
---@param other JLogFacetCounter
M.override = function(counter, other)
  for name, field in pairs(other.fields) do
    if counter.fields[name] then
      counter.fields[name] = field
    elseif not entry_model.aliased(name) then
      counter.names[#counter.names + 1] = name
      counter.fields[name] = field
    end
  end
end

---Count every scalar under `value` by its dotted name, depth first; arrays and nulls are skipped.
---@param counter JLogFacetCounter
---@param parent string dotted path of `value`, "" at the top
---@param value table
---@param only table<string, boolean>|nil count only these names
---@param rounded table<string, boolean>|nil names skipped so far
---@return table<string, boolean>|nil rounded names of numbers the decoder may have rounded, left uncounted
local function walk(counter, parent, value, only, rounded)
  local paths = counter.paths
  local name

  for key, child in pairs(value) do
    name = entry_model.child_path(paths, parent, key)
    if type(child) == "table" and not vim.islist(child) then
      rounded = walk(counter, name, child, only, rounded)
    elseif type(child) ~= "table" and child ~= vim.NIL and (not only or only[name]) then
      if not only and entry_model.is_inexact(child) then
        rounded = rounded or {}
        rounded[name] = true
      else
        M.add_value(counter, name, child)
      end
    end
  end

  return rounded
end

---Count one entry's fields: its decoded object by dotted name, then its labels as `labels.<name>`.
---@param counter JLogFacetCounter
---@param entry JLogEntry
---@param decoded table|nil
M.count_entry = function(counter, entry, decoded)
  local rounded = decoded and walk(counter, "", decoded)

  if rounded then
    -- rare: the decoder may have rounded these numbers, so their literals are counted instead
    walk(counter, "", entry_model.decode_exact(entry) or {}, rounded)
  end
  for key, value in pairs(entry.labels or {}) do
    M.add_value(counter, entry_model.child_path(counter.paths, "labels", key), value)
  end
end

---Count the fields of every entry in `entries` into `counter`, decoding each.
---@param counter JLogFacetCounter
---@param entries JLogEntry[]
M.count_entries = function(counter, entries)
  for _, entry in ipairs(entries) do
    M.count_entry(counter, entry, entry_model.decode(entry))
  end
end

---Adds another counter's fields into `counter`, keeping at most MAX_DISTINCT values per field.
---@param counter JLogFacetCounter
---@param fields table<string, {counts: table<string, integer>, distinct: integer, capped: boolean, present: integer}>
M.merge = function(counter, fields)
  local field
  local dropped

  for name, incoming in pairs(fields) do
    field = counter.fields[name]
    dropped = false

    if not field then
      field = { counts = {}, distinct = 0, capped = false, present = 0 }
      counter.fields[name] = field
      counter.names[#counter.names + 1] = name
    end
    field.present = field.present + incoming.present

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
      present = field.present,
      label = is_label(name),
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
