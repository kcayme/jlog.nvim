-- Field values the engine has read, one column per field, kept while the same entries stay at the same indexes.

---@class JLogFieldCache
---@field entries JLogEntry[]|nil the list the columns were read from
---@field owners JLogEntry[] the entry each slot was read from
---@field columns table<string, any[]> per field path, the value read at each index

local M = {}

-- a value read as missing, so it is not read again
local MISSING = {}

---@return JLogFieldCache
M.new = function()
  return { owners = {}, columns = {} }
end

---Ready the cache for reads over `entries`: another list (a new page, the cross-page matches) drops every value.
---@param cache JLogFieldCache
---@param entries JLogEntry[]
M.use = function(cache, entries)
  if cache.entries ~= entries then
    cache.entries, cache.owners, cache.columns = entries, {}, {}
  end
end

---`read(path)` of the entry at `index`, read once while that entry stays there; object values are not kept.
---@param cache JLogFieldCache
---@param index integer
---@param entry JLogEntry
---@param path string
---@param read fun(path: string): any
---@return any
M.get = function(cache, index, entry, path, read)
  local column, value

  -- a sort or reload put another entry here, so the values read for the old one go
  if cache.owners[index] ~= entry then
    for _, other in pairs(cache.columns) do
      other[index] = nil
    end
    cache.owners[index] = entry
  end
  column = cache.columns[path]
  if not column then
    column = {}
    cache.columns[path] = column
  end
  value = column[index]
  if value == MISSING then
    return nil
  end
  if value ~= nil then
    return value
  end
  value = read(path)
  -- an object would keep the entry's whole decode alive
  if type(value) ~= "table" then
    column[index] = value == nil and MISSING or value
  end

  return value
end

return M
