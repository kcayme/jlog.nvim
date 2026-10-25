local entry_model = require("jlog.parse.entry")
local filter = require("jlog.query.filter")
local gc = require("jlog.core.gc")
local layout = require("jlog.workspace.layout")

local M = {}

---@param lines string[]
---@param errors {lnum: integer, msg: string}[]
---@return string[] valid
---@return JLogFilterError[] invalid
local function split_invalid(lines, errors)
  local bad = {}
  local valid = {}
  local invalid = {}

  for _, err in ipairs(errors) do
    bad[err.lnum] = err.msg
  end
  for lnum, line in ipairs(lines) do
    if bad[lnum] then
      invalid[#invalid + 1] = { text = line, msg = bad[lnum] }
    elseif line:find("%S") then
      valid[#valid + 1] = line
    end
  end

  return valid, invalid
end

---An action that sets filters or the group replaces what was typed in the sidebar.
---@param ws JLogWorkspace
local function discard_sidebar_edits(ws)
  vim.bo[ws.sidebar.bufnr].modified = false
end

---@param view JLogView
---@param index integer entry index to land on, or the nearest one that is shown
local function goto_nearest(view, index)
  for distance = 0, #view.ws.entries do
    for _, candidate in ipairs({ index - distance, index + distance }) do
      if view.entry_item[candidate] then
        view:goto_entry(candidate)

        return
      end
    end
  end
end

---@param ws JLogWorkspace
---@param shown integer
---@return string
M.winbar_text = function(ws, shown)
  local parts = { "jlog", ws.format, shown .. "/" .. #ws.entries }

  if ws.pages and ws.page then
    parts[#parts + 1] = "page " .. ws.page .. "/" .. (ws.pages:count() or "…")
  end
  if #ws.state.filters > 0 then
    parts[#parts + 1] = table.concat(ws.state.filters, " · ")
  end
  if ws.state.group then
    parts[#parts + 1] = "group: "
      .. ws.state.group
      .. (ws.state.group_limit and (" (" .. ws.state.group_limit .. " groups)") or "")
  end
  if ws.state.limit then
    parts[#parts + 1] = "limit " .. ws.state.limit
  end

  return table.concat(parts, " · ")
end

---Filter, group and render, then count facets; work past the first ~12ms tick continues later, a newer apply wins.
---@param ws JLogWorkspace
---@param on_done fun()|nil called once the view has rendered
---@param counted JLogFacetCounter|nil facets of every entry, counted while loading; used when no filter applies
---@param keep_counts boolean|nil the matches cannot change (only the order does): keep final field counts
M.apply = function(ws, on_done, counted, keep_counts)
  local state = ws.state
  local field = state.group and filter.unescape_field(state.group)
  local counts = layout.window_in_tab(ws, ws.sidebar.bufnr) ~= nil
  local lines = vim.deepcopy(state.filters)
  local pred, errors, invalid
  local prefilled
  -- only final counts can be kept: a count still running is stopped by this apply's query
  local keep = keep_counts and not ws.sidebar.stale

  -- lines that failed before stay pending until edited, so re-validate them with the rest
  for _, err in ipairs(ws.sidebar.errors) do
    lines[#lines + 1] = err.text
  end
  pred, errors = filter.compile(lines)
  state.filters, invalid = split_invalid(lines, errors)
  ws.sidebar:set_errors(invalid)
  -- every entry matches, so the load's counts are this apply's counts
  prefilled = counts and counted ~= nil and #state.filters == 0
  if not keep then
    ws.store:set_counts(prefilled and counted or nil)
    -- the sidebar keeps the last counts until this apply's are counted
    ws.sidebar.stale = counts and not prefilled
  end
  if ws.sidebar.stale then
    ws.sidebar:refresh()
  end

  local function publish(items, shown)
    local generation = ws.store.generation
    local cursor_entry = ws.view:entry_at_cursor()

    ws.shown = shown
    ws.view:set_winbar(M.winbar_text(ws, shown))
    ws.sidebar:refresh(prefilled and { counter = counted } or nil)
    -- counting does not wait for the render: a superseded render never calls its on_done
    if ws.sidebar.stale then
      ws.store:count(function(counter)
        ws.sidebar.stale = false
        -- unsaved FILTERS edits are kept; the next sync renders the counts
        ws.sidebar:refresh({ counter = counter })
      end)
    end
    ws.view:render(items, function()
      -- a newer apply that has not rendered yet supersedes this render too
      if ws.store.generation ~= generation or ws.closed then
        return
      end
      ws.rendered = generation
      if cursor_entry then
        ws.view:goto_entry(cursor_entry)
      end
      if on_done then
        on_done()
      end
    end)
  end

  ws.store:query(pred, field, publish)
end

---@param ws JLogWorkspace
---@param clause string
M.add_filter = function(ws, clause)
  table.insert(ws.state.filters, clause)
  discard_sidebar_edits(ws)
  ws:apply()
end

---@param ws JLogWorkspace
M.clear_filters = function(ws)
  ws.state.filters = {}
  ws.sidebar:set_errors({})
  discard_sidebar_edits(ws)
  ws:apply()
end

---Clear filters, group and both limits in one apply.
---@param ws JLogWorkspace
M.clear_all = function(ws)
  ws.state.filters = {}
  ws.state.group = nil
  ws.state.group_limit = nil
  ws.state.limit = nil
  ws.sidebar:set_errors({})
  discard_sidebar_edits(ws)
  ws:apply()
end

---@param ws JLogWorkspace
---@param field string|nil nil clears the group
M.set_group = function(ws, field)
  ws.state.group = field ~= "" and field or nil
  discard_sidebar_edits(ws)
  ws:apply()
end

-- shortcut: re-runs the filter scan (not the counts); keep the last matches if reversing 500k entries feels slow
---@param ws JLogWorkspace
M.toggle_reverse = function(ws)
  ws.state.reverse = not ws.state.reverse
  -- the same entries match in either order, so their field counts stay
  ws:apply(nil, nil, true)
end

---Show the new entries `from..` in a flat view without a full apply. Returns false when an apply is needed.
---@param ws JLogWorkspace
---@param old_count integer entry count before the append
---@param old_key string|nil key of the last old entry before the append
---@return boolean
M.extend = function(ws, old_count, old_key)
  local entries, view, counter = ws.entries, ws.view, ws.store.counter
  local pred = filter.compile(ws.state.filters)
  local changed = old_key ~= nil and entry_model.key(entries[old_count]) ~= old_key
  local indexes = {}
  local refresh, entry, decoded, shown, matches
  local ctx = {
    get = function(path)
      return entry_model.get(entry, decoded, path, ws.opts)
    end,
  }

  for index = changed and old_count or old_count + 1, #entries do
    entry = entries[index]
    decoded = entry_model.decode(entry)
    ctx.raw = entry_model.key(entry)
    matches = pred(ctx)
    shown = view.entry_item[index] ~= nil
    if shown and not matches then
      return false
    end
    if shown then
      refresh = index
    elseif matches then
      indexes[#indexes + 1] = index
    end
    if matches and index > old_count then
      ws.store:count_appended(index, entry, decoded)
    end
  end

  if ws.state.reverse then
    view:prepend(vim.fn.reverse(indexes), refresh)
  else
    view:append(indexes, refresh)
  end
  ws.shown = #view.items
  view:set_winbar(M.winbar_text(ws, ws.shown))
  if counter then
    ws.sidebar:refresh({ counter = counter, partial = true })
  end

  return true
end

---Make `entries` the workspace's entries and free the old ones, which compiled code would otherwise keep alive.
---@param ws JLogWorkspace
---@param entries JLogEntry[]
M.set_entries = function(ws, entries)
  ws.entries = entries
  gc.release_compiled()
end

---Swap in rebuilt entries, keeping state: expanded entries and the cursor entry are found again by key.
---@param ws JLogWorkspace
---@param entries JLogEntry[]
M.replace_entries = function(ws, entries)
  local old, state = ws.entries, ws.state
  local cursor = ws.view:entry_at_cursor()
  local cursor_key = cursor and entry_model.key(old[cursor])
  local new_index, expanded = {}, {}
  local entry_key, target

  if cursor_key or next(state.expanded) then
    for index, entry in ipairs(entries) do
      entry_key = entry_model.key(entry)
      new_index[entry_key] = new_index[entry_key] or index
    end
  end
  for index in pairs(state.expanded) do
    target = new_index[entry_model.key(old[index])]
    if target then
      expanded[target] = true
    end
  end
  state.expanded = expanded
  M.set_entries(ws, entries)
  cursor = cursor_key and new_index[cursor_key] or cursor
  ws:apply(function()
    if cursor then
      goto_nearest(ws.view, cursor)
    end
  end)
end

return M
