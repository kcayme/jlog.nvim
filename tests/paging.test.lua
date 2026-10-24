local reader = require("jlog.parse.reader")
local store = require("jlog.query.store")
local workspace = require("jlog.workspace")

local function wait(cond)
  assert.is_true(vim.wait(3000, cond, 20))
end

---@param count integer
---@param from integer|nil
---@return string[]
local function log_lines(count, from)
  local lines = {}

  for index = from or 1, (from or 1) + count - 1 do
    lines[#lines + 1] = string.format('{"msg":"m%d","level":"INFO"}', index)
  end

  return lines
end

describe("paging", function()
  local notify = vim.notify
  local timing = vim.deepcopy(workspace.timing)
  local store_timing = vim.deepcopy(store.timing)
  local load_sizes = vim.deepcopy(workspace.load_sizes)
  local chunk_size = reader.chunk_size
  local open_index_ns = workspace.open_index_ns
  local path
  local ws

  local function settled()
    return not ws.loading and ws.indexing == nil and ws.rendered == ws.store.generation
  end

  before_each(function()
    require("jlog").setup({ paging = { size = 10, overlap = 2 } })
    path = vim.fn.tempname() .. ".jsonl"
    vim.fn.writefile(log_lines(35), path)
  end)

  after_each(function()
    vim.notify = notify
    workspace.timing = vim.deepcopy(timing)
    store.timing = vim.deepcopy(store_timing)
    workspace.load_sizes = vim.deepcopy(load_sizes)
    reader.chunk_size = chunk_size
    workspace.open_index_ns = open_index_ns
    if ws then
      ws:close()
      ws = nil
    end
    vim.fn.delete(path)
  end)

  it("should open on the newest page and show the page in the winbar", function()
    ws = workspace.open({ path = path })
    assert.are.equal(1, ws.page)
    wait(settled)
    assert.is_truthy(ws.view.winbar_text:find("page 1/4", 1, true))
    assert.is_truthy(vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, 1, false)[1]:find("m35", 1, true))
  end)

  it("should keep filters and reset the cursor when changing page", function()
    local winid

    ws = workspace.open({ path = path })
    wait(settled)
    ws:add_filter("msg~m")
    winid = vim.fn.bufwinid(ws.view.bufnr)
    vim.api.nvim_win_set_cursor(winid, { 5, 0 })
    assert.is_true(ws:goto_page(2))
    wait(function()
      return settled() and ws.page == 2
    end)
    assert.are.same({ "msg~m" }, ws.state.filters)
    assert.are.equal(1, vim.api.nvim_win_get_cursor(winid)[1])
    assert.is_truthy(vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, 1, false)[1]:find("m27", 1, true))
  end)

  it("should refuse a page that is not indexed yet", function()
    local messages = {}

    vim.fn.writefile(log_lines(5000), path)
    workspace.timing = { tick_ns = 0, publish_ns = timing.publish_ns }
    store.timing = { tick_ns = 0 }
    workspace.open_index_ns = 0
    vim.notify = function(msg)
      messages[#messages + 1] = msg
    end
    ws = workspace.open({ path = path })
    assert.is_false(ws:goto_page(4))
    assert.are.same({ "jlog: indexing pages…", "jlog: still indexing pages" }, messages)
    -- the wrong end of the log is never shown while page 1 is unknown
    assert.are.same({ "" }, vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false))
    assert.is_nil(ws.view.winbar_text:find("indexing", 1, true))
    assert.is_true(vim.wait(10000, function()
      return ws.indexing == nil
    end))
    assert.are.equal("jlog: indexed " .. ws.pages:count() .. " pages", messages[#messages])
  end)

  it("should show the newest entry as the first screen of a large log", function()
    require("jlog").setup({ paging = { size = 5000, overlap = 20 } })
    vim.fn.writefile(log_lines(20000), path)
    ws = workspace.open({ path = path })
    assert.is_truthy(vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, 1, false)[1]:find("m20000", 1, true))
  end)

  it("should switch pages while page 1 is still loading", function()
    require("jlog").setup({ paging = { size = 3000, overlap = 2 } })
    vim.fn.writefile(log_lines(7000), path)
    workspace.timing = { tick_ns = 0, publish_ns = timing.publish_ns }
    store.timing = { tick_ns = 0 }
    reader.chunk_size = 10
    ws = workspace.open({ path = path })
    wait(function()
      return ws.pages:known() >= 2
    end)
    assert.is_true(ws.loading)
    reader.chunk_size = chunk_size
    assert.is_true(ws:goto_page(2))
    wait(function()
      return settled() and ws.page == 2
    end)
    -- page 2 is lines 1001..4000 with 2 lines of overlap on each side
    assert.are.same({ 999, 4002, 3004 }, { ws.entries[1].src, ws.entries[#ws.entries].src, #ws.entries })
    -- the dropped page 1 load does not come back later
    vim.wait(300)
    assert.are.same({ 2, 999, 3004 }, { ws.page, ws.entries[1].src, #ws.entries })
  end)

  it("should dim overlap entries", function()
    local set_extmark = vim.api.nvim_buf_set_extmark
    local dimmed = {}

    ws = workspace.open({ path = path })
    wait(settled)
    ws:goto_page(2)
    wait(function()
      return settled() and ws.page == 2
    end)
    vim.api.nvim_set_current_win(vim.fn.bufwinid(ws.view.bufnr))
    vim.api.nvim_buf_set_extmark = function(bufnr, ns, row, col, opts)
      if opts.hl_group == "JLogOverlap" then
        dimmed[row + 1] = true
      end

      return set_extmark(bufnr, ns, row, col, opts)
    end
    vim.cmd("redraw!")
    vim.api.nvim_buf_set_extmark = set_extmark
    -- page 2 shows lines 27..14, newest first: 27, 26 and 15, 14 are overlap
    assert.are.same({ [1] = true, [2] = true, [13] = true, [14] = true }, dimmed)
  end)

  it("should leave page 2 alone when lines are appended", function()
    local entries

    ws = workspace.open({ path = path })
    wait(settled)
    ws:goto_page(2)
    wait(function()
      return settled() and ws.page == 2
    end)
    entries = ws.entries
    vim.fn.writefile(log_lines(10, 36), path, "a")
    ws:reload()
    wait(function()
      return ws.view.winbar_text:find("page 2/5", 1, true) ~= nil
    end)
    assert.are.equal(entries, ws.entries)
    assert.are.equal(14, #ws.entries)
  end)

  it("should show appended lines on page 1", function()
    ws = workspace.open({ path = path })
    wait(settled)
    vim.fn.writefile(log_lines(1, 36), path, "a")
    ws:reload()
    wait(function()
      return vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, 1, false)[1]:find("m36", 1, true) ~= nil
    end)
    assert.are.equal(1, ws.page)
  end)

  it("should return to the page holding the cursor entry after a rewrite", function()
    local tmp = path .. ".tmp"
    local entries

    ws = workspace.open({ path = path })
    wait(settled)
    ws:goto_page(3)
    wait(function()
      return settled() and ws.page == 3
    end)
    -- line 5 of page 3 is source line 13, in its core
    vim.api.nvim_win_set_cursor(vim.fn.bufwinid(ws.view.bufnr), { 5, 0 })
    entries = ws.entries
    vim.fn.writefile(log_lines(35), tmp)
    vim.uv.fs_rename(tmp, path)
    ws:reload()
    wait(function()
      return settled() and ws.entries ~= entries
    end)
    assert.are.equal(3, ws.page)
  end)

  it("should page a newest-first loki export from its start", function()
    local elements = {}

    for index = 1, 35 do
      elements[index] =
        string.format('{"line":"{\\"msg\\":\\"m%d\\"}","timestamp":"%d","fields":{"app":"a"}}', index, 1000 - index)
    end
    vim.fn.writefile(vim.split("[" .. table.concat(elements, ",\n") .. "]", "\n"), path)
    ws = workspace.open({ path = path })
    wait(settled)
    assert.are.equal("loki", ws.format)
    assert.are.same({ 1, 12 }, { ws.entries[1].src, #ws.entries })
    vim.notify = function() end
    assert.is_false(ws:goto_page(1.5))
    ws:goto_page(4)
    wait(function()
      return settled() and ws.page == 4
    end)
    assert.are.same({ 29, 35, 7 }, { ws.entries[1].src, ws.entries[#ws.entries].src, #ws.entries })
    assert.are.same({ 31, 35 }, ws.core)
  end)

  it("should show a newest-first loki export's first elements before its pages are indexed", function()
    local elements = {}

    -- page 1 is known only once more elements are scanned than one scan call reads
    require("jlog").setup({ paging = { size = 2000, overlap = 2 } })
    for index = 1, 5000 do
      elements[index] =
        string.format('{"line":"{\\"msg\\":\\"m%d\\"}","timestamp":"%d","fields":{"app":"a"}}', index, 10000 - index)
    end
    vim.fn.writefile(vim.split("[" .. table.concat(elements, ",\n") .. "]", "\n"), path)
    workspace.timing.tick_ns = 0
    store.timing.tick_ns = 0
    workspace.load_sizes.first = 3
    reader.chunk_size = 3
    ws = workspace.open({ path = path })

    assert.is_nil(ws.page)
    assert.are.same({ 1, 3 }, { ws.entries[1].src, #ws.entries })
    assert.are.equal(1, ws.view.items[1].idx)
    workspace.timing = vim.deepcopy(timing)
    store.timing = vim.deepcopy(store_timing)
    wait(settled)
    assert.are.same({ 1, 1, 2002 }, { ws.page, ws.entries[1].src, #ws.entries })
  end)

  it("should refuse a page that is not a whole number", function()
    local message

    ws = workspace.open({ path = path })
    wait(settled)
    vim.notify = function(msg)
      message = msg
    end
    assert.is_false(ws:goto_page(1.5))
    assert.are.equal("jlog: no page 1.5", message)
    assert.are.equal(1, ws.page)
  end)

  it("should step from the page still loading when ]p is pressed twice", function()
    require("jlog").setup({ paging = { size = 3000, overlap = 2 } })
    vim.fn.writefile(log_lines(12000), path)
    ws = workspace.open({ path = path })
    wait(function()
      return settled() and ws.pages:count() == 4
    end)
    reader.chunk_size = 10
    vim.api.nvim_set_current_win(vim.fn.bufwinid(ws.view.bufnr))
    vim.api.nvim_feedkeys("]p", "mx", false)
    assert.is_true(ws.loading)
    vim.api.nvim_feedkeys("]p", "mx", false)
    reader.chunk_size = chunk_size
    wait(function()
      return settled() and ws.page == 3
    end)
    vim.wait(200)
    assert.are.equal(3, ws.page)
  end)

  it("should not page a file of exactly paging.size entries", function()
    vim.fn.writefile(log_lines(10), path)
    ws = workspace.open({ path = path })
    wait(settled)
    assert.is_nil(ws.pages)
    assert.is_nil(ws.view.winbar_text:find("page", 1, true))
  end)
end)
