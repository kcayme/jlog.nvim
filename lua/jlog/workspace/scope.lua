local gc = require("jlog.core.gc")
local scan_mod = require("jlog.query.scan")

local M = {}

---@alias JLogScope "page"|"all"
---@alias JLogReplaceEntries fun(ws: JLogWorkspace, entries: JLogEntry[]) swaps in entries, keeping cursor and expanded

---The filters a scan was made for, as one string.
---@param ws JLogWorkspace
---@return string
local function key_of(ws)
  return table.concat(ws.state.filters, "\n")
end

---@param ws JLogWorkspace
---@param message string
---@param level integer|nil
local function notify(ws, message, level)
  if not ws.closed then
    vim.notify("jlog: " .. message, level)
  end
end

---The page holding the cursor entry in `all` scope, else the page shown or asked for.
---@param ws JLogWorkspace
---@return integer|nil
local function current_page(ws)
  local cursor

  if ws.scope ~= "all" then
    return ws.target_page or ws.page
  end
  cursor = ws.view:entry_at_cursor()

  return cursor and ws.pages:page_of(ws.entries[cursor].src) or ws.page
end

---Back to page scope, on `page` or the one holding the cursor entry, keeping the cursor and expanded entries.
---@param ws JLogWorkspace
---@param page integer|nil
local function leave(ws, page)
  ws:goto_page(page or current_page(ws), true)
end

---Show every page's matches in one view, read from the done scan; over `paging.size` matches it stays on a page.
---@param ws JLogWorkspace
---@param replace JLogReplaceEntries
local function show_all(ws, replace)
  local scan = ws.scan
  local cap = ws.opts.paging.size

  if #scan.matches > cap then
    if ws.scope == "all" then
      leave(ws)
    end
    notify(
      ws,
      ("%d matches across pages, over paging.size %d: narrow the filter"):format(#scan.matches, cap),
      vim.log.levels.WARN
    )

    return
  end
  ws.reading = scan_mod.entries(scan, function(entries)
    ws.reading = nil
    if ws.scan ~= scan or ws.closed then
      return
    end
    ws.scope, ws.core = "all", nil
    replace(ws, entries)
  end)
end

---Stop the workspace's scan and forget its counts.
---@param ws JLogWorkspace
M.cancel = function(ws)
  if ws.scan then
    scan_mod.cancel(ws.scan)
    -- compiled code keeps the closures it ran, and with them the dropped scan's matches and candidates
    gc.release_compiled()
  end
  if ws.reading then
    ws.reading()
  end
  ws.scan, ws.scan_key, ws.scan_index, ws.page_counts, ws.reading, ws.enter_pending = nil, nil, nil, nil, nil, nil
end

---Keep the scan made for the current filters and page index; drop any other, and with `start` begin a new one.
---@param ws JLogWorkspace
---@param start boolean
---@param on_change fun() called as the scan progresses and once it is done
---@param replace JLogReplaceEntries
M.update = function(ws, start, on_change, replace)
  local index, key = ws.pages, key_of(ws)

  if ws.scan and ws.scan_index == index and ws.scan_key == key then
    return
  end
  M.cancel(ws)
  -- the combined view shows a filter's matches: without one it goes back to a page
  if key == "" and ws.scope == "all" and not ws.closed then
    leave(ws)
  end
  if not start or not index or ws.indexing or key == "" or ws.closed then
    return
  end
  ws.scan_key, ws.scan_index = key, index
  ws.scan = scan_mod.run(index, ws.format, vim.deepcopy(ws.state.filters), ws.opts, on_change, function(scan)
    ws.page_counts = scan_mod.page_counts(scan, index)
    -- compiled code keeps the finished scan's closures and every candidate they checked; flushed once they returned
    vim.defer_fn(gc.release_compiled, 0)
    on_change()
    -- the combined view follows a changed filter, and one asked for while counting opens now
    if ws.scope == "all" or ws.enter_pending then
      ws.enter_pending = nil
      show_all(ws, replace)
    end
  end)
end

---Show the matches of every page in one view (`all`), or go back to a page (`page`).
---@param ws JLogWorkspace
---@param scope JLogScope
---@param replace JLogReplaceEntries
M.set = function(ws, scope, replace)
  local why

  if scope == ws.scope then
    return
  end
  if scope == "page" then
    leave(ws)

    return
  end
  if not ws.pages then
    why = "the log fits one page"
  elseif #ws.state.filters == 0 then
    why = "a filter is needed to show matches from every page"
  elseif not ws.scan then
    why = "still indexing pages"
  end
  if why then
    notify(ws, why)

    return
  end
  if not ws.scan.done then
    ws.enter_pending = true
    notify(ws, "counting matches on every page; they show once counted")

    return
  end
  show_all(ws, replace)
end

---Toggle between the combined view of every page's matches and the page holding the cursor entry.
---@param ws JLogWorkspace
---@param replace JLogReplaceEntries
M.toggle = function(ws, replace)
  M.set(ws, ws.scope == "all" and "page" or "all", replace)
end

---Show the page after (`dir` 1) or before (-1) the current one; in `all` scope, the cursor entry's page is current.
---@param ws JLogWorkspace
---@param dir integer
M.step_page = function(ws, dir)
  local page = current_page(ws)

  if page then
    ws:goto_page(page + dir)
  end
end

---Show the nearest page after (`dir` 1) or before (-1) the current one that has matches; notify when there is none.
---@param ws JLogWorkspace
---@param dir integer
M.goto_match_page = function(ws, dir)
  local counts = ws.page_counts
  local page = current_page(ws)
  local why

  if not page then
    why = "the log fits one page"
  elseif #ws.state.filters == 0 then
    why = "no filter to match"
  elseif not counts then
    why = "still counting matches"
  end
  page = page and page + dir
  while not why and counts[page] do
    if counts[page] > 0 then
      ws:goto_page(page)

      return
    end
    page = page + dir
  end
  notify(ws, why or ("no " .. (dir > 0 and "later" or "earlier") .. " page has matches"))
end

---The matches on every page once counted; else nil and how far the count is; nil, nil when nothing is counted.
---@param ws JLogWorkspace
---@return integer|nil total
---@return number|nil fraction
M.total = function(ws)
  local scan = ws.scan

  if not scan then
    return nil, nil
  end
  if scan.done then
    return #scan.matches, nil
  end

  return nil, scan.fraction
end

return M
