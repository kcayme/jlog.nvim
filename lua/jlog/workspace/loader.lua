local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local gc = require("jlog.core.gc")
local layout = require("jlog.workspace.layout")
local pages = require("jlog.parse.pages")
local progress_mod = require("jlog.core.progress")
local query = require("jlog.workspace.query")
local reader = require("jlog.parse.reader")
local source = require("jlog.parse.source")
local watcher = require("jlog.workspace.watcher")

---@class JLogFirstSlice
---@field entries JLogEntry[] read before the first screen
---@field order "asc"|"desc"|"none"
---@field index JLogPageIndex|nil
---@field paged boolean|nil nil while not known yet
---@field range JLogPageRange|nil page 1, when paged
---@field early boolean the first entries are the top of the view, so they show before the rest is read
---@field tail boolean|nil page 1 is the end of a jsonl file
---@field read JLogReader
---@field more number|nil fraction read, nil once the slice was everything

local M = {}

-- how long a load waiting on worker threads sleeps before it checks again
local WAIT_MS = 2

-- lines or array elements parsed before the first screen
M.load_sizes = { first = 2000 }
-- tick_ns: work per tick before yielding (keeps ticks ~16ms); publish_ns: how often new fields reach the sidebar
M.timing = { tick_ns = 12e6, publish_ns = 250e6 }
-- how long open may index to find page 1 before its first screen
M.open_index_ns = 150e6

-- shortcut: a sync read of 100MB takes tens of ms; read async if that ever matters
---@param path string
---@return string|nil
---@return string|nil err
local function read_file(path)
  local fd, err = vim.uv.fs_open(path, "r", 438)
  local stat, data

  if not fd then
    return nil, err
  end
  stat, err = vim.uv.fs_fstat(fd)
  if stat then
    data, err = vim.uv.fs_read(fd, stat.size, 0)
  end
  vim.uv.fs_close(fd)

  return data, err
end

---Show newly found fields while a load or apply runs, at most every `timing.publish_ns`; unsaved edits are kept.
---@param ws JLogWorkspace
---@param counter JLogFacetCounter
---@param progress string
local function publish_partial(ws, counter, progress)
  local now = vim.uv.hrtime()

  -- a counter only gains names, so a count above the published one means new fields
  if #counter.names <= ws.published.names or now - ws.published.at < M.timing.publish_ns then
    return
  end
  if not layout.window_in_tab(ws, ws.sidebar.bufnr) or vim.bo[ws.sidebar.bufnr].modified then
    return
  end
  ws.published.at = now
  ws.sidebar:refresh({ counter = counter, partial = true, progress = progress })
end

---Parse the rest of the source into `entries` in chunks across event-loop ticks, then call `on_done` once.
---@param ws JLogWorkspace
---@param entries JLogEntry[] mutated
---@param read JLogReader
---@param on_done fun(entries: JLogEntry[])
---@param counter JLogFacetCounter|nil counts the facets of the loaded JSON entries, from the load's own decode
---@param token table|nil the load stops, dropping what it read, once `ws.load_token` is another load's
---@param notified boolean|nil a load past its first tick says so once, and again when it is done
local function load_rest(ws, entries, read, on_done, counter, token, notified)
  local deadline = vim.uv.hrtime() + M.timing.tick_ns
  local fraction, progress, waiting
  local count_entry = counter
    and function(entry, decoded)
      facets.add(counter, entry_model.flatten(entry, decoded))
    end
  -- field counts a worker thread found for a chunk it parsed
  local merge_fields = counter and function(fields)
    facets.merge(counter, fields)
  end

  if ws.closed or (token and ws.load_token ~= token) then
    return
  end
  repeat
    fraction, waiting = read(entries, count_entry, nil, merge_fields)
  until not fraction or waiting or vim.uv.hrtime() >= deadline
  if fraction then
    progress = "loading " .. math.floor(fraction * 100) .. "%"
    if not notified then
      progress_mod.begin(ws.key, "load", "loading…")
    end
    -- with a filter set, the sidebar shows the filtered counts of the last apply instead
    if counter and #ws.state.filters == 0 then
      publish_partial(ws, counter, progress)
    end
    vim.defer_fn(function()
      load_rest(ws, entries, read, on_done, counter, token, true)
    end, waiting and WAIT_MS or 0)

    return
  end

  progress_mod.finish(ws.key, "load", "loaded " .. #entries .. " entries")
  ws.loading = nil
  on_done(entries)
  if ws.reload_pending then
    ws.reload_pending = nil
    ws:reload()
  end
end

---Record whether the loaded file lists the newest first; a toggled sort stays toggled.
---@param ws JLogWorkspace
---@param order "asc"|"desc"|"none"
local function set_stored_order(ws, order)
  if (order == "desc") ~= ws.stored_newest_first then
    ws.stored_newest_first = order == "desc"
    ws.state.reverse = not ws.state.reverse
  end
end

---A page index over `text`, or nil for an unordered loki export, which is sorted whole instead.
---@param text string
---@param format JLogFormat
---@param order "asc"|"desc"|"none"
---@param opts JLogOptions
---@return JLogPageIndex|nil
local function new_index(text, format, order, opts)
  if format == "loki" and order == "none" then
    return nil
  end

  return pages.new(text, format, opts.paging, (opts.view.sort == "desc") ~= (order == "desc"))
end

---Whether `index` has more than one page, or nil while that is not known yet.
---@param index JLogPageIndex
---@return boolean|nil
local function is_paged(index)
  if index:count() == 1 then
    return false
  end

  return index:known() >= 1 or nil
end

---The page shown holds the end of the source, where appended lines go.
---@param ws JLogWorkspace
---@return boolean
local function holds_end(ws)
  return ws.page == (ws.pages.from_end and 1 or ws.pages:count())
end

---@param ws JLogWorkspace
local function refresh_winbar(ws)
  if not ws.loading and ws.rendered == ws.store.generation then
    ws.view:set_winbar(query.winbar_text(ws, ws.shown))
  end
end

---Finish a collector cycle in time-boxed steps, or a replaced ~100MB text is collected in one long tick.
---@param ws JLogWorkspace
---@param on_done fun()|nil
local function collect(ws, on_done)
  local deadline = vim.uv.hrtime() + M.timing.tick_ns

  if ws.closed then
    return
  end
  if gc.step(deadline) then
    if on_done then
      vim.defer_fn(on_done, 0)
    end

    return
  end
  vim.defer_fn(function()
    collect(ws, on_done)
  end, 0)
end

---Scan `index` in ticks while it is `ws.indexing`; `on_known(paged)` runs once paging is known (or done: `wait_done`).
---@param ws JLogWorkspace
---@param index JLogPageIndex
---@param on_known fun(paged: boolean)|nil
---@param wait_done boolean|nil
local function scan_pages(ws, index, on_known, wait_done)
  local done

  if ws.closed or ws.indexing ~= index then
    return
  end
  done = index:scan(vim.uv.hrtime() + M.timing.tick_ns)
  if on_known and (done or (not wait_done and is_paged(index))) then
    on_known(is_paged(index) == true)
    on_known = nil
  end
  if not done then
    vim.defer_fn(function()
      scan_pages(ws, index, on_known, wait_done)
    end, 0)

    return
  end
  ws.indexing = nil
  if ws.index_notified then
    ws.index_notified = nil
    progress_mod.finish(ws.key, "index", "indexed " .. index:count() .. " pages")
  end
  -- an index rebuilt after an append replaces the one in use
  if ws.pages and ws.pages ~= index then
    ws.pages = index
    collect(ws)
  end
  -- the pages are known now: a rendered view starts counting the filters' matches on each, an old count is dropped
  query.update_scan(ws, not ws.loading and ws.rendered == ws.store.generation)
  refresh_winbar(ws)
  -- PAGE shows the page count in place of `…`
  ws.sidebar:show_status()
end

---Put the cursor on the page's first own entry at the top of window `winid`, past the neighbour's dimmed overlap.
---@param ws JLogWorkspace
---@param winid integer
local function land_on_core(ws, winid)
  local view = ws.view
  local item, src

  for row, item_index in ipairs(view.line_item) do
    item = view.items[item_index]
    src = item.kind == "entry" and ws.entries[item.idx].src
    if src and src >= ws.core[1] and src <= ws.core[2] then
      vim.api.nvim_win_set_cursor(winid, { row, 0 })
      vim.api.nvim_win_call(winid, function()
        vim.cmd("normal! zt")
      end)

      return
    end
  end
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })
end

---Load page `page` of `ws.pages` in ticks, then show it; `keep` keeps the cursor entry and expanded entries by key.
---@param ws JLogWorkspace
---@param page integer
---@param keep boolean|nil
local function load_page(ws, page, keep)
  local range = ws.pages:range(page)
  local read = reader.page(ws.pages.text, ws.format, range)
  local counter = facets.counter()
  local token = {}

  ws.loading, ws.load_token, ws.target_page = true, token, page
  vim.defer_fn(function()
    load_rest(ws, {}, read, function(loaded)
      local winid

      ws.page, ws.core = page, M.core_of(range)
      if keep then
        query.replace_entries(ws, loaded)

        return
      end
      ws.state.expanded = {}
      query.set_entries(ws, loaded)
      ws:apply(function()
        winid = vim.fn.bufwinid(ws.view.bufnr)
        if winid ~= -1 then
          land_on_core(ws, winid)
        end
      end, counter)
    end, counter, token)
  end, 0)
end

---Index the text again with the lines appended since, in a tick of its own: joining ~100MB takes ~20ms.
---@param ws JLogWorkspace
local function reindex(ws)
  local base = ws.indexing or ws.pages
  local index

  -- shortcut: the whole text is indexed again per append; extend the index in place if appends get frequent
  if ws.closed or not ws.appended or not base then
    return
  end
  index = pages.new(base.text .. table.concat(ws.appended), ws.format, ws.opts.paging, base.from_end)
  ws.appended = nil
  ws.indexing = index
  vim.defer_fn(function()
    scan_pages(ws, index)
  end, 0)
end

---Re-read a rewritten source and index it again; a paged one returns to the page holding the cursor entry.
---@param ws JLogWorkspace
local function rebuild(ws)
  local text, err = M.read_source(ws.path, ws.bufnr)
  local order, index

  if err then
    -- a missing file is reported by the watcher, which waits for it to come back
    if not ws.path or vim.uv.fs_stat(ws.path) then
      vim.notify("jlog: cannot reload: " .. tostring(err), vim.log.levels.WARN)
    end

    return
  end
  if ws.path then
    watcher.snapshot(ws, text)
  end
  order = source.element_order(text, ws.format)
  index = new_index(text, ws.format, order, ws.opts)
  ws.indexing, ws.appended = index, nil
  -- parsed in chunks like at open; the old entries stay shown until the new ones are complete
  ws.loading = true

  local function on_known(paged)
    local cursor = ws.view:entry_at_cursor()

    set_stored_order(ws, order)
    if paged then
      ws.pages = index
      load_page(ws, index:page_of(cursor and ws.entries[cursor].src), true)

      return
    end
    ws.pages, ws.page, ws.core, ws.target_page = nil, nil, nil, nil
    vim.defer_fn(function()
      load_rest(ws, {}, reader.source(text, ws.format, order, M.timing.tick_ns), function(loaded)
        query.replace_entries(ws, loaded)
      end)
    end, 0)
  end

  if not index then
    on_known(false)

    return
  end
  vim.defer_fn(function()
    scan_pages(ws, index, on_known, true)
  end, 0)
end

---Load the rest of the first page, or of a source that is not paged, after the first screen.
---@param ws JLogWorkspace
---@param entries JLogEntry[] read so far; `ws.entries` when `early`
---@param read JLogReader
---@param early boolean the entries read so far are shown already
---@param counter JLogFacetCounter counts of `entries` when `early`
local function load_first(ws, entries, read, early, counter)
  local token = {}

  ws.loading, ws.load_token = true, token
  vim.defer_fn(function()
    if early then
      load_rest(ws, entries, read, function()
        ws:apply(nil, counter)
      end, counter, token)

      return
    end
    -- shown once loaded and ordered, counted by that apply
    load_rest(ws, entries, read, function(loaded)
      query.set_entries(ws, loaded)
      ws:apply()
    end, nil, token)
  end, 0)
end

---@param path string|nil
---@param bufnr integer|nil
---@return string|nil
---@return string|nil err
M.read_source = function(path, bufnr)
  if path then
    return read_file(path)
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "no file or valid buffer to open"
  end

  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

---@param range JLogPageRange
---@return integer[]
M.core_of = function(range)
  return {
    range.core_first_line or range.core_first_element,
    range.core_last_line or range.core_last_element,
  }
end

---Show page `page`, keeping filters, group and mode; false when that page is not indexed (yet).
---@param ws JLogWorkspace
---@param page integer
---@return boolean
M.goto_page = function(ws, page)
  local range = ws.pages and page % 1 == 0 and ws.pages:range(page)

  if not range then
    vim.notify("jlog: " .. (ws.indexing and "still indexing pages" or ("no page " .. page)), vim.log.levels.WARN)

    return false
  end
  -- a page load still running is dropped for this one
  load_page(ws, page)

  return true
end

---Pick up changes to the source: a grown jsonl file only parses its new lines; anything else is rebuilt.
---@param ws JLogWorkspace
M.reload = function(ws)
  local tail, old_count, old_key, shown

  if ws.closed then
    return
  end
  if ws.loading then
    ws.reload_pending = true

    return
  end
  tail = ws.path and ws.format == "jsonl" and watcher.read_appended(ws) or nil
  if not tail then
    rebuild(ws)

    return
  end
  -- appended lines belong to the page holding the end of the file; another page stays as it is
  shown = not ws.pages or holds_end(ws)
  old_count = #ws.entries
  old_key = old_count > 0 and entry_model.key(ws.entries[old_count]) or nil
  if shown then
    source.append_lines(ws.entries, vim.split(tail:sub(1, -2), "\n", { plain = true }), ws.next_lnum)
  end
  watcher.advance(ws, tail)
  if tail == "" then
    return
  end
  if ws.pages then
    if not ws.appended then
      ws.appended = {}
      vim.defer_fn(function()
        collect(ws, function()
          reindex(ws)
        end)
      end, 0)
    end
    ws.appended[#ws.appended + 1] = tail
    if shown then
      ws.core[2] = ws.next_lnum - 1
    end
  end
  if not shown then
    return
  end
  -- shortcut: a limited view re-applies on each append; extend could trim instead if that feels slow
  if
    ws.state.group
    or ws.state.limit
    or ws.rendered ~= ws.store.generation
    or not query.extend(ws, old_count, old_key)
  then
    -- the last entry took continuation lines, so its old lines must not be reused
    if old_key and entry_model.key(ws.entries[old_count]) ~= old_key then
      ws.view:forget(old_count)
    end
    ws:apply()
  end
end

---The first slice of the source, read before the first screen, and how the rest of it loads.
---@param text string
---@param format JLogFormat
---@param opts JLogOptions
---@param count_entry fun(entry: JLogEntry, decoded: table) counts the facets of an entry shown early
---@return JLogFirstSlice
M.prepare = function(text, format, opts, count_entry)
  local order, read, early, more
  local index, paged, range, deadline, tail
  local entries = {}

  order = source.element_order(text, format)
  -- index until page 1 is known, so the first screen is page 1; the rest of the index follows in ticks
  index = new_index(text, format, order, opts)
  -- page 1 starts where the source does unless it is the end: then the first screen needs no more than a tick of it
  if index then
    deadline = vim.uv.hrtime() + (index.from_end and M.open_index_ns or M.timing.tick_ns)
    repeat
      index:scan(math.min(deadline, vim.uv.hrtime() + M.timing.tick_ns))
      paged = is_paged(index)
    until paged ~= nil or vim.uv.hrtime() >= deadline
  end
  range = paged and index:range(1)
  -- the first elements show early only when they are the top of the view; jsonl reverses
  early = format == "jsonl" or (order ~= "none" and (opts.view.sort == "desc") == (order == "desc"))
  -- a page from the file's end shows newest first: its first screen is the page's last lines, then the whole page
  tail = range and format == "jsonl" and index.from_end
  read = tail and reader.tail(text, range, M.load_sizes.first)
    or range and reader.page(text, format, range)
    or reader.source(text, format, order, M.timing.tick_ns)
  -- only the first lines or elements are parsed before the first screen; the rest follows in chunks
  if not index or paged ~= nil or not index.from_end then
    more = read(entries, early and count_entry or nil, M.load_sizes.first)
  end

  return {
    entries = entries,
    order = order,
    index = index,
    paged = paged,
    range = range,
    early = early,
    tail = tail,
    read = read,
    more = more,
  }
end

---Load what `prepare` left: index the rest, then load page 1 or the rest of the first slice's source.
---@param ws JLogWorkspace
---@param slice JLogFirstSlice
---@param counter JLogFacetCounter counts of the slice when it was shown early
M.start = function(ws, slice, counter)
  local entries, read, early, more = slice.entries, slice.read, slice.early, slice.more
  local index, paged, range, tail = slice.index, slice.paged, slice.range, slice.tail

  if index and not index.done then
    ws.indexing = index
    vim.defer_fn(function()
      -- once paging is known: page 1 loads, or the load goes on from the first slice (none if page 1 is the end)
      scan_pages(ws, index, paged == nil and function(has_pages)
        if has_pages then
          ws.pages = index
          load_page(ws, 1)

          return
        end
        load_first(ws, entries, read, early, counter)
      end or nil)
    end, 0)
  end
  if paged == nil and ws.indexing then
    -- page 1 is not known yet: the start of the source, or an empty view rather than the wrong end of the log
    ws.loading, ws.index_notified = true, true
    progress_mod.begin(ws.key, "index", "indexing pages…")
  elseif tail and range.core_last_line - range.first_src + 1 > M.load_sizes.first then
    load_page(ws, 1)
  elseif not tail and more then
    load_first(ws, entries, read, early, counter)
  end
end

return M
