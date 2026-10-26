-- FIELDS order: pinned fields first, then alphabetical or by entries.
local M = {}

local ROLES = { time = true, level = true, message = true, status = true }

---Most entries first, ties by name, labels after the other fields.
---@param left JLogFacet
---@param right JLogFacet
---@return boolean
local function by_count(left, right)
  if left.label ~= right.label then
    return right.label
  end
  if left.present ~= right.present then
    return left.present > right.present
  end

  return left.name < right.name
end

---Append the facet named `name` to `list` once.
---@param list JLogFacet[]
---@param placed table<string, boolean>
---@param by_name table<string, JLogFacet>
---@param name string
local function place(list, placed, by_name, name)
  if by_name[name] and not placed[name] then
    placed[name] = true
    list[#list + 1] = by_name[name]
  end
end

---The facets `pinned` names, in its order: a field path, or a role standing for its keys in `opts.fields`.
---@param by_name table<string, JLogFacet>
---@param opts JLogOptions
---@return JLogFacet[] pinned
---@return table<string, boolean> placed
local function pinned_facets(by_name, opts)
  local pinned, placed = {}, {}

  for _, entry in ipairs(opts.sidebar.fields.pinned) do
    place(pinned, placed, by_name, entry)
    for _, alias in ipairs(ROLES[entry] and opts.fields[entry] or {}) do
      place(pinned, placed, by_name, alias)
    end
  end

  return pinned, placed
end

---FIELDS in display order: pinned, then the rest by `sort`; a count sort holds `previous` until the counts are final.
---@param facets JLogFacet[] as `facets.result` gives them: alphabetical, labels last
---@param opts JLogOptions
---@param previous JLogFacet[] the facets shown before, in their order
---@param final boolean the counts are complete
---@return JLogFacet[]
M.order = function(facets, opts, previous, final)
  local by_name = {}
  local ordered, placed, rest
  local by_count_sort = opts.sidebar.fields.sort == "count"

  for _, facet in ipairs(facets) do
    by_name[facet.name] = facet
  end
  ordered, placed = pinned_facets(by_name, opts)
  rest = {}
  -- rows hold still while counts come in; new fields go last
  if by_count_sort and not final then
    for _, facet in ipairs(previous) do
      place(rest, placed, by_name, facet.name)
    end
  end
  for _, facet in ipairs(facets) do
    if not placed[facet.name] then
      rest[#rest + 1] = facet
    end
  end
  if by_count_sort and final then
    table.sort(rest, by_count)
  end
  vim.list_extend(ordered, rest)

  return ordered
end

return M
