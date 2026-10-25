local gc = require("jlog.core.gc")
local scan_mod = require("jlog.query.scan")

local M = {}

---The filters a scan was made for, as one string.
---@param ws JLogWorkspace
---@return string
local function key_of(ws)
  return table.concat(ws.state.filters, "\n")
end

---Stop the workspace's scan and forget its counts.
---@param ws JLogWorkspace
M.cancel = function(ws)
  if ws.scan then
    scan_mod.cancel(ws.scan)
    -- compiled code keeps the closures it ran, and with them the dropped scan's matches and candidates
    gc.release_compiled()
  end
  ws.scan, ws.scan_key, ws.scan_index, ws.page_counts = nil, nil, nil, nil
end

---Keep the scan made for the current filters and page index; drop any other, and with `start` begin a new one.
---@param ws JLogWorkspace
---@param start boolean
---@param on_change fun() called as the scan progresses and once it is done
M.update = function(ws, start, on_change)
  local index, key = ws.pages, key_of(ws)

  if ws.scan and ws.scan_index == index and ws.scan_key == key then
    return
  end
  M.cancel(ws)
  if not start or not index or ws.indexing or key == "" or ws.closed then
    return
  end
  ws.scan_key, ws.scan_index = key, index
  ws.scan = scan_mod.run(index, ws.format, vim.deepcopy(ws.state.filters), ws.opts, on_change, function(scan)
    ws.page_counts = scan_mod.page_counts(scan, index)
    -- compiled code keeps the finished scan's closures and every candidate they checked; flushed once they returned
    vim.defer_fn(gc.release_compiled, 0)
    on_change()
  end)
end

---Show the nearest page after (`dir` 1) or before (-1) the page shown that has matches; notify when there is none.
---@param ws JLogWorkspace
---@param dir integer
M.goto_match_page = function(ws, dir)
  local counts = ws.page_counts
  local page = ws.target_page or ws.page
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
  vim.notify("jlog: " .. (why or ("no " .. (dir > 0 and "later" or "earlier") .. " page has matches")))
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
