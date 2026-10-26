local scan = require("jlog.query.scan")
local workers = require("jlog.worker")
local workspace = require("jlog.workspace")

local function wait(cond)
  assert.is_true(vim.wait(5000, cond, 10))
end

---Lines `from..from+count-1`; every fifth has status 500.
---@param count integer
---@param from integer|nil
---@return string[]
local function log_lines(count, from)
  local lines = {}

  for index = from or 1, (from or 1) + count - 1 do
    lines[#lines + 1] = string.format('{"msg":"m%d","status":%d}', index, index % 5 == 0 and 500 or 200)
  end

  return lines
end

describe("scope", function()
  local timing = vim.deepcopy(scan.timing)
  local main_chunk_bytes = scan.main_chunk_bytes
  local path
  local ws

  local function settled()
    return not ws.loading and ws.indexing == nil and ws.rendered == ws.store.generation
  end

  local function winbar()
    return ws.view.winbar_text or ""
  end

  before_each(function()
    -- the combined view only when asked for, so tests of `A` do not race the default swap
    require("jlog").setup({ paging = { size = 10, overlap = 2, filter_scope = "page" } })
    path = vim.fn.tempname() .. ".jsonl"
    vim.fn.writefile(log_lines(35), path)
  end)

  after_each(function()
    scan.timing = vim.deepcopy(timing)
    scan.main_chunk_bytes = main_chunk_bytes
    workers.disabled = nil
    if ws then
      ws:close()
      ws = nil
    end
    vim.fn.delete(path)
    require("jlog").setup()
  end)

  it("should show the total of every page in the winbar once scanned", function()
    ws = workspace.open({ path = path })
    wait(settled)
    ws:add_filter("status=500")
    wait(function()
      return winbar():find("7 in all", 1, true) ~= nil
    end)
    assert.is_truthy(winbar():find("page 1/4 · 7 in all", 1, true))
  end)

  it("should show how far the count is while scanning", function()
    local texts = {}
    local set_winbar

    -- main-thread chunks of one line, reported every tick
    workers.disabled = true
    scan.main_chunk_bytes, scan.timing.tick_ns, scan.timing.publish_ns = 1, 0, 0
    ws = workspace.open({ path = path })
    wait(settled)
    set_winbar = ws.view.set_winbar
    ws.view.set_winbar = function(view, text)
      texts[#texts + 1] = text
      set_winbar(view, text)
    end
    ws:add_filter("status=500")
    wait(function()
      return winbar():find("7 in all", 1, true) ~= nil
    end)
    assert.is_true(#vim.tbl_filter(function(text)
      return text:find("… in all %d+%%") ~= nil
    end, texts) > 0)
  end)

  it("should show no total without a filter", function()
    ws = workspace.open({ path = path })
    wait(settled)
    vim.wait(200)
    assert.is_nil(ws.scan)
    assert.is_nil(winbar():find("in all", 1, true))
  end)

  it("should show no total when the log fits one page", function()
    require("jlog").setup({ paging = { size = 100, overlap = 2 } })
    ws = workspace.open({ path = path })
    wait(settled)
    ws:add_filter("status=500")
    wait(settled)
    vim.wait(200)
    assert.is_nil(ws.scan)
    assert.is_nil(winbar():find("in all", 1, true))
  end)

  it("should drop a scan when a newer filter is applied", function()
    local first

    ws = workspace.open({ path = path })
    wait(settled)
    ws:add_filter("status=500")
    wait(function()
      return ws.scan ~= nil
    end)
    first = ws.scan
    ws:add_filter("msg~m1")
    assert.is_true(first.cancelled)
    -- m10, m15, m20 ... m35 have status 500; of them only m10 and m15 start with m1
    wait(function()
      return winbar():find("2 in all", 1, true) ~= nil
    end)
  end)

  it("should keep the scan when only the page changes", function()
    local counted

    ws = workspace.open({ path = path })
    wait(settled)
    ws:add_filter("status=500")
    wait(function()
      return ws.scan and ws.scan.done
    end)
    counted = ws.scan
    assert.is_true(ws:goto_page(2))
    wait(function()
      return settled() and ws.page == 2
    end)
    assert.are.equal(counted, ws.scan)
    assert.is_truthy(winbar():find("page 2/4 · 7 in all", 1, true))
  end)

  it("should drop the scan on close", function()
    local running

    workers.disabled = true
    scan.main_chunk_bytes, scan.timing.tick_ns = 1, 0
    ws = workspace.open({ path = path })
    wait(settled)
    ws:add_filter("status=500")
    wait(function()
      return ws.scan ~= nil
    end)
    running = ws.scan
    ws:close()
    ws = nil
    assert.is_true(running.cancelled)
  end)

  it("should count appended lines once the pages are indexed again", function()
    ws = workspace.open({ path = path })
    wait(settled)
    ws:add_filter("status=500")
    wait(function()
      return winbar():find("7 in all", 1, true) ~= nil
    end)
    vim.fn.writefile(log_lines(10, 36), path, "a")
    ws:reload()
    -- m40 and m45
    wait(function()
      return winbar():find("9 in all", 1, true) ~= nil
    end)
  end)

  ---The text of the sidebar's virtual status lines (SORT, PAGE and the counts).
  local function status_texts()
    local ns = vim.api.nvim_create_namespace("jlog.status")
    local texts = {}

    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ws.sidebar.bufnr, ns, 0, -1, { details = true })) do
      for _, line in ipairs(mark[4].virt_lines) do
        texts[#texts + 1] = table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, line))
      end
    end

    return texts
  end

  it("should list the matches of each page under PAGE once scanned", function()
    ws = workspace.open({ path = path })
    wait(settled)
    ws:add_filter("status=500")
    wait(function()
      return ws.page_counts ~= nil
    end)
    assert.is_true(vim.tbl_contains(status_texts(), "  1:2  2:2  3:2  4:1  (]m next match, A all)"))
  end)

  it("should highlight the page shown and dim every other page in the counts", function()
    local ns = vim.api.nvim_create_namespace("jlog.status")
    local groups = {}

    ws = workspace.open({ path = path })
    wait(settled)
    ws:add_filter("msg=m33 OR msg=m3")
    wait(function()
      return ws.page_counts ~= nil
    end)
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ws.sidebar.bufnr, ns, 0, -1, { details = true })) do
      for _, line in ipairs(mark[4].virt_lines) do
        for _, chunk in ipairs(line) do
          groups[chunk[1]] = chunk[2] or false
        end
      end
    end
    assert.are.equal("JLogPageCurrent", groups["1:1"])
    assert.are.equal("JLogHint", groups["2:0"])
    assert.are.equal("JLogHint", groups["4:1"])
  end)

  it("should wrap the page counts to the sidebar width", function()
    local width, counts

    ws = workspace.open({ path = path })
    wait(settled)
    vim.api.nvim_win_set_width(vim.fn.bufwinid(ws.sidebar.bufnr), 14)
    width = vim.api.nvim_win_get_width(vim.fn.bufwinid(ws.sidebar.bufnr))
    ws:add_filter("status=500")
    wait(function()
      return ws.page_counts ~= nil
    end)
    ws.sidebar:show_status()
    counts = vim.tbl_filter(function(text)
      return text:find("^  %d+:") ~= nil
    end, status_texts())
    assert.is_true(#counts > 1)
    for _, text in ipairs(counts) do
      -- the key hint may run past the width; the counts never do
      assert.is_true(#text:gsub("  %(.*%)$", "") <= width, text)
    end
  end)

  it("should jump to the next and previous page with matches, skipping empty ones", function()
    local notify = vim.notify
    local notified

    ws = workspace.open({ path = path })
    wait(settled)
    ws:add_filter("msg=m33 OR msg=m3")
    wait(function()
      return ws.page_counts ~= nil
    end)
    assert.are.same({ 1, 0, 0, 1 }, ws.page_counts)
    ws:goto_match_page(1)
    wait(function()
      return settled() and ws.page == 4
    end)
    vim.notify = function(msg)
      notified = msg
    end
    ws:goto_match_page(1)
    vim.notify = notify
    assert.are.equal("jlog: no later page has matches", notified)
    ws:goto_match_page(-1)
    wait(function()
      return settled() and ws.page == 1
    end)
  end)

  it("should jump with ]m and leave it unmapped when set to false", function()
    ws = workspace.open({ path = path })
    wait(settled)
    assert.is_truthy(vim.fn.maparg("]m", "n", false, true).buffer)
    ws:close()

    require("jlog").setup({
      paging = { size = 10, overlap = 2, filter_scope = "page" },
      keymaps = { next_match_page = false },
    })
    ws = workspace.open({ path = path })
    wait(settled)
    assert.are.same({}, vim.fn.maparg("]m", "n", false, true))
  end)

  describe("all pages", function()
    local function texts_of(entries)
      return vim.tbl_map(function(entry)
        return entry.raw:match('"msg":"(m%d+)"')
      end, entries)
    end

    local function counted()
      return ws.scan ~= nil and ws.scan.done and settled()
    end

    local function in_all()
      return ws.scope == "all" and settled()
    end

    it("should show every page's matches in one view with toggle_scope", function()
      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(counted)
      ws:toggle_scope()
      wait(in_all)
      assert.are.same({ "m5", "m10", "m15", "m20", "m25", "m30", "m35" }, texts_of(ws.entries))
      assert.is_nil(ws.core)
      assert.is_truthy(winbar():find("7/7 · all pages", 1, true))
    end)

    it("should keep the cursor entry and expanded entries entering and leaving", function()
      local cursor

      ws = workspace.open({ path = path })
      wait(settled)
      ws:goto_page(2)
      wait(function()
        return settled() and ws.page == 2
      end)
      ws:add_filter("status=500")
      wait(counted)
      -- page 2 holds m16..m25 of its own: m20 is the first, newest-first view puts m25 at the top
      ws.view:goto_entry(vim.fn.index(texts_of(ws.entries), "m20") + 1)
      ws.view:toggle_entry()
      ws:toggle_scope()
      wait(in_all)
      cursor = ws.view:entry_at_cursor()
      assert.are.equal("m20", texts_of({ ws.entries[cursor] })[1])
      assert.is_true(ws.state.expanded[cursor])
      ws:toggle_scope()
      wait(function()
        return ws.scope == "page" and settled()
      end)
      assert.are.equal(2, ws.page)
      cursor = ws.view:entry_at_cursor()
      assert.are.equal("m20", texts_of({ ws.entries[cursor] })[1])
      assert.is_true(ws.state.expanded[cursor])
    end)

    it("should refuse more matches than paging.size and stay on the page", function()
      local notify = vim.notify
      local notified

      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=200")
      wait(counted)
      vim.notify = function(msg)
        notified = msg
      end
      ws:toggle_scope()
      vim.wait(300)
      vim.notify = notify
      assert.are.equal("page", ws.scope)
      assert.are.equal("jlog: 28 matches across pages, over paging.size 10: narrow the filter", notified)
    end)

    it("should open once a running count completes", function()
      workers.disabled = true
      scan.main_chunk_bytes, scan.timing.tick_ns = 1, 0
      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(function()
        return ws.scan ~= nil
      end)
      ws:toggle_scope()
      assert.are.equal("page", ws.scope)
      wait(in_all)
      assert.are.equal(7, #ws.entries)
    end)

    it("should not dim any entry", function()
      local set_extmark = vim.api.nvim_buf_set_extmark
      local dimmed = false

      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(counted)
      ws:toggle_scope()
      wait(in_all)
      vim.api.nvim_set_current_win(vim.fn.bufwinid(ws.view.bufnr))
      vim.api.nvim_buf_set_extmark = function(bufnr, ns, row, col, opts)
        dimmed = dimmed or opts.hl_group == "JLogOverlap"

        return set_extmark(bufnr, ns, row, col, opts)
      end
      vim.cmd("redraw!")
      vim.api.nvim_buf_set_extmark = set_extmark
      assert.is_false(dimmed)
    end)

    it("should go to the page after the cursor entry's page with next_page", function()
      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(counted)
      ws:toggle_scope()
      wait(in_all)
      -- m20 is on page 2
      ws.view:goto_entry(vim.fn.index(texts_of(ws.entries), "m20") + 1)
      ws:step_page(1)
      wait(function()
        return ws.scope == "page" and settled() and ws.page == 3
      end)
    end)

    it("should rescan and rebuild when the filter changes", function()
      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(counted)
      ws:toggle_scope()
      wait(in_all)
      -- as a sidebar :w does: the filter lines replaced in one apply, here by a broader filter
      ws.state.filters = { "msg=m1 OR msg=m33" }
      ws:apply()
      wait(function()
        return in_all() and #ws.entries == 2
      end)
      assert.are.same({ "m1", "m33" }, texts_of(ws.entries))
    end)

    it("should not rescan on group, reverse or mode", function()
      local counting

      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(counted)
      ws:toggle_scope()
      wait(in_all)
      counting = ws.scan
      ws:set_group("status")
      wait(settled)
      ws:toggle_reverse()
      wait(settled)
      ws.view:toggle_mode()
      wait(settled)
      assert.are.equal(counting, ws.scan)
      assert.are.equal("all", ws.scope)
    end)

    it("should go back to a page when the filters are cleared", function()
      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(counted)
      ws:toggle_scope()
      wait(in_all)
      ws:clear_filters()
      wait(function()
        return ws.scope == "page" and settled() and #ws.entries > 7
      end)
    end)

    it("should go back to a page when the new filter matches more than paging.size", function()
      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(counted)
      ws:toggle_scope()
      wait(in_all)
      ws:clear_filters()
      ws:add_filter("status=200")
      wait(function()
        return ws.scope == "page" and settled() and ws.scan and ws.scan.done
      end)
    end)

    it("should add appended matching lines once the pages are indexed again", function()
      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(counted)
      ws:toggle_scope()
      wait(in_all)
      vim.fn.writefile(log_lines(10, 36), path, "a")
      ws:reload()
      wait(function()
        return in_all() and #ws.entries == 9
      end)
      assert.are.same({ "m5", "m10", "m15", "m20", "m25", "m30", "m35", "m40", "m45" }, texts_of(ws.entries))
    end)

    ---Field counts once the sidebar has them for the current apply.
    local function field(name)
      wait(function()
        return not ws.sidebar.stale and ws.store.counter ~= nil
      end)

      return ws.store.counter.fields[name]
    end

    it("should not check the filter again when grouping the combined matches", function()
      local filter = require("jlog.query.filter")
      local compile = filter.compile
      local checks = 0

      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(counted)
      ws:toggle_scope()
      wait(in_all)
      filter.compile = function(...)
        local pred, errors, exact = compile(...)

        return function(ctx)
          checks = checks + 1

          return pred(ctx)
        end, errors, exact
      end
      ws:set_group("msg")
      wait(settled)
      filter.compile = compile
      assert.are.equal(0, checks)
      assert.are.equal(7, #ws.entries)
      assert.are.same({ ["500"] = 7, ["200"] = 28 }, field("status").counts)
    end)

    it("should count fields over the combined matches", function()
      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(counted)
      ws:toggle_scope()
      wait(in_all)
      assert.are.equal(7, field("msg").present)
    end)

    it("should list a picked field's other values from every page for an exact filter", function()
      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(counted)
      ws:toggle_scope()
      wait(in_all)
      assert.are.same({ ["500"] = 7, ["200"] = 28 }, field("status").counts)
    end)

    it("should list a picked field's values from the combined matches when its other lines have a regex", function()
      ws = workspace.open({ path = path })
      wait(settled)
      ws.state.filters = { "status=500", "msg~m1" }
      ws:apply()
      wait(counted)
      ws:toggle_scope()
      wait(in_all)
      -- m10 and m15
      assert.are.same({ ["500"] = 2 }, field("status").counts)
    end)
  end)

  describe("filter_scope all", function()
    local function in_all()
      return ws.scope == "all" and settled()
    end

    before_each(function()
      require("jlog").setup({ paging = { size = 10, overlap = 2, filter_scope = "all" } })
    end)

    it("should show the page's matches at once, then every page's once counted", function()
      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(settled)
      -- page 1 holds m26..m35 of its own and m24, m25 as overlap
      assert.are.equal("page", ws.scope)
      wait(in_all)
      assert.are.equal(7, #ws.entries)
    end)

    it("should stay on the page without a notice when more than paging.size match", function()
      local notify = vim.notify
      local notified

      ws = workspace.open({ path = path })
      wait(settled)
      vim.notify = function(msg)
        notified = msg
      end
      ws:add_filter("status=200")
      wait(function()
        return winbar():find("28 in all", 1, true) ~= nil
      end)
      vim.wait(200)
      vim.notify = notify
      assert.are.equal("page", ws.scope)
      assert.is_nil(notified)
    end)

    it("should keep a page for later filters once A picked it", function()
      ws = workspace.open({ path = path })
      wait(settled)
      ws:add_filter("status=500")
      wait(in_all)
      ws:toggle_scope()
      wait(function()
        return ws.scope == "page" and settled()
      end)
      ws:add_filter("msg~m1")
      wait(function()
        return winbar():find("2 in all", 1, true) ~= nil
      end)
      vim.wait(200)
      assert.are.equal("page", ws.scope)
    end)
  end)
end)
