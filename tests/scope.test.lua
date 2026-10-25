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
    require("jlog").setup({ paging = { size = 10, overlap = 2 } })
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
end)
