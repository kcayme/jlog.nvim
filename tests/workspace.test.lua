local config = require("jlog.config")
local parallel = require("jlog.parse.parallel")
local store = require("jlog.store")
local view = require("jlog.ui.view")
local workers = require("jlog.workers")
local workspace = require("jlog.workspace")

local gen = dofile("bench/gen.lua")

local function header_texts(bufnr)
  local ns = vim.api.nvim_create_namespace("jlog.view.header")

  return vim.tbl_map(function(mark)
    return mark[4].virt_lines[1][1][1]
  end, vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true }))
end

describe("workspace", function()
  local timing = vim.deepcopy(workspace.timing)
  local store_timing = vim.deepcopy(store.timing)
  local view_tick_ns = view.tick_ns

  before_each(function()
    config.setup()
  end)
  after_each(function()
    workspace.timing = vim.deepcopy(timing)
    store.timing = vim.deepcopy(store_timing)
    view.tick_ns = view_tick_ns
    pcall(vim.cmd, "silent! tabonly")
  end)

  it("should open a tab with view and sidebar for a loki export", function()
    local ws = assert(workspace.open({ path = vim.fn.fnamemodify("tests/fixtures/loki.json", ":p") }))
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(ws.tab))
    assert.are.equal("loki", ws.format)
  end)

  it("should filter, group and report counts in the winbar", function()
    local ws = workspace.open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
    ws:add_filter("status>=500")
    ws:set_group("request_id")
    local lines = vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false)
    assert.is_truthy(header_texts(ws.view.bufnr)[1]:find("^▾ r1"))
    assert.are.equal(4, #lines) -- panic entry, its 2 continuation lines, request completed
    assert.is_truthy(vim.wo[vim.fn.bufwinid(ws.view.bufnr)].winbar:find("status>=500", 1, true))
  end)

  it("should focus the existing workspace when opened twice", function()
    local path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p")
    local first = workspace.open({ path = path })
    assert.are.equal(first, workspace.open({ path = path }))
  end)

  it("should forget a workspace whose tab was closed without q", function()
    local path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p")
    vim.cmd("tabnew") -- earlier tests may leave this workspace in the only tab, which cannot be closed
    local first = workspace.open({ path = path })
    vim.cmd("tabclose")
    assert.is_nil(workspace.find(path))
    local second = workspace.open({ path = path })
    assert.are_not.equal(first, second)
    assert.is_true(vim.api.nvim_tabpage_is_valid(second.tab))
  end)

  it("should close the workspace when the view window is quit", function()
    local path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p")
    local first, second

    vim.cmd("tabnew")
    first = workspace.open({ path = path })
    vim.api.nvim_set_current_win(vim.fn.bufwinid(first.view.bufnr))
    vim.cmd("quit")
    assert.is_true(vim.wait(1000, function()
      return workspace.find(path) == nil
    end, 10))
    assert.is_true(first.closed)
    second = workspace.open({ path = path })
    assert.are_not.equal(first, second)
    assert.is_true(vim.api.nvim_buf_is_valid(second.view.bufnr))
    second:add_filter("level=ERROR")
  end)

  it("should close the workspace and wipe both view buffers whichever mode is shown", function()
    local path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p")
    local ws, buffers

    vim.cmd("tabnew")
    ws = workspace.open({ path = path })
    ws.view:toggle_mode()
    assert.is_true(vim.wait(2000, function()
      return ws.view.complete
    end))
    buffers = { ws.view.bufnr, ws.view.cache.bufnr }
    vim.api.nvim_set_current_win(vim.fn.bufwinid(ws.view.bufnr))
    vim.cmd("quit")
    assert.is_true(vim.wait(1000, function()
      return ws.closed
    end, 10))
    assert.is_false(vim.api.nvim_buf_is_valid(buffers[1]))
    assert.is_false(vim.api.nvim_buf_is_valid(buffers[2]))
  end)

  it("should group, count and filter large numbers exactly", function()
    config.setup({ view = { sort = "asc" } })
    local buf = vim.api.nvim_create_buf(true, false)
    local ws, lines, values

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      '{"msg":"a","id":1234567890123456,"n":12345678901234567890}',
      '{"msg":"b","id":1234567890123457,"n":0.1}',
      '{"msg":"c","err":"x {\\"big\\":-12345678901234567890}"}',
    })
    ws = assert(workspace.open({ bufnr = buf }))
    values = {}
    for _, facet in ipairs(ws.sidebar.facets) do
      for _, top in ipairs(facet.top) do
        values[facet.name .. "=" .. top.value] = top.count
      end
    end
    assert.are.same(
      { ["id=1234567890123456"] = 1, ["id=1234567890123457"] = 1, ["n=12345678901234567890"] = 1, ["n=0.1"] = 1 },
      {
        ["id=1234567890123456"] = values["id=1234567890123456"],
        ["id=1234567890123457"] = values["id=1234567890123457"],
        ["n=12345678901234567890"] = values["n=12345678901234567890"],
        ["n=0.1"] = values["n=0.1"],
      }
    )
    ws:set_group("id")
    lines = header_texts(ws.view.bufnr)
    assert.is_truthy(lines[1]:find("^▾ 123456789012345[67]  1 entry$"))
    assert.are.equal(3, #lines)
    ws:set_group(nil)
    ws:add_filter("n=12345678901234567890")
    assert.is_truthy(ws.view.winbar_text:find(" 1/3 ", 1, true))
    ws:clear_filters()
    ws:add_filter("err.big=-12345678901234567890")
    assert.is_truthy(ws.view.winbar_text:find(" 1/3 ", 1, true))
  end)

  it("should open plain text when forced", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "not json", "still not" })
    local ws = assert(workspace.open({ bufnr = buf, force = true }))
    assert.are.equal(2, #ws.entries)
  end)

  it("should open a bracket-prefixed jsonl file and a truncated loki export when forced", function()
    local prefixed = vim.fn.tempname() .. ".log"
    local truncated = vim.fn.tempname() .. ".json"
    local ws, err

    vim.fn.writefile({ '[INFO] {"msg":"a","level":"INFO"}', '[WARN] {"msg":"b","level":"WARN"}' }, prefixed)
    vim.fn.writefile({ '[{"line":"{\\"msg\\":\\"a\\"}","timestamp":"1","fields":{}},{"line":"{\\"ms' }, truncated)
    ws, err = workspace.open({ path = prefixed, force = true })
    assert.is_nil(err)
    assert.are.equal("jsonl", ws.format)
    assert.are.equal(2, #ws.entries)
    ws, err = workspace.open({ path = truncated, force = true })
    assert.is_nil(err)
    -- the broken element and everything after it are kept as plain entries
    assert.are.equal("loki", ws.format)
    assert.is_true(vim.wait(2000, function()
      return not ws.loading
    end))
    assert.are.equal(2, #ws.entries)
    assert.is_nil(ws.entries[2].json_at)
    vim.fn.delete(prefixed)
    vim.fn.delete(truncated)
  end)

  describe("open_raw", function()
    local tmp, size

    -- an empty buffer named after the file, from `:edit` before the file existed (e.g. before a download finished)
    local function edit_then_create()
      vim.cmd("edit " .. vim.fn.fnameescape(tmp))
      vim.fn.writefile(vim.fn.readfile("tests/fixtures/app.jsonl", "b"), tmp, "b")
      size = vim.fn.getfsize(tmp)
    end

    before_each(function()
      tmp = vim.fn.tempname() .. ".jsonl"
    end)

    local function assert_raw_and_write()
      assert.are.same(vim.fn.readfile(tmp), vim.api.nvim_buf_get_lines(0, 0, -1, false))
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
      vim.cmd("write")
      assert.are.equal(size, vim.fn.getfsize(tmp))
    end

    it("should read the file after the workspace replaced an empty buffer for it", function()
      vim.cmd("tabnew")
      edit_then_create()
      local ws = assert(workspace.open({ path = tmp }))
      ws:open_raw(2)
      assert_raw_and_write()
    end)

    it("should read the file when an empty unread buffer for it exists elsewhere", function()
      vim.cmd("tabnew")
      edit_then_create()
      vim.cmd("tabnew")
      local ws = assert(workspace.open({ path = tmp }))
      ws:open_raw(2)
      assert_raw_and_write()
    end)
  end)

  it("should tune the garbage collector only while a workspace is open", function()
    -- setstepmul returns the previous value, so setting it reads it
    collectgarbage("setstepmul", 200)
    local ws = assert(workspace.open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") }))
    assert.are.equal(400, collectgarbage("setstepmul", 400))
    ws:close()
    assert.are.equal(200, collectgarbage("setstepmul", 200))
  end)

  it("should apply in chunks and let a newer apply supersede an in-flight one", function()
    config.setup({ view = { sort = "asc" } })
    local lines = {}
    for i = 1, 25000 do
      lines[i] = string.format('{"msg":"m%d","status":%d}', i, i % 2 == 0 and 500 or 200)
    end
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ws = assert(workspace.open({ bufnr = buf }))
    local done = 0
    local notify = vim.notify
    local messages = {}
    assert.is_true(vim.wait(10000, function()
      return not ws.loading
    end))
    vim.notify = function(msg)
      if msg:find("applying", 1, true) then
        messages[#messages + 1] = msg
      end
    end
    ws.state.filters = { "status=500" }
    -- a 25k-entry scan can fit in one tick: both scans run past their first tick, so the first is in flight
    store.timing = { tick_ns = 0 }
    ws:apply(function()
      done = done + 1
    end)
    ws.state.filters = { "status=200", "msg~m1" }
    ws:apply(function()
      done = done + 10
    end)
    store.timing = vim.deepcopy(store_timing)
    assert.is_true(vim.wait(10000, function()
      return done > 0
    end))
    vim.notify = notify
    assert.are.equal(10, done)
    -- the superseded apply never says it is done
    assert.are.equal("jlog: applying…", messages[1])
    assert.are.equal("jlog: applying done", messages[#messages])
    assert.are.equal(1, #vim.tbl_filter(function(msg)
      return msg == "jlog: applying done"
    end, messages))
    assert.is_truthy(ws.view.winbar_text:find("/25000 ", 1, true))
    assert.is_truthy(vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, 1, false)[1]:find("^m1 "))
  end)

  it("should not report a superseded apply as done when its scan finished in one tick", function()
    local lines = {}
    local done = 0
    local buf, ws

    for index = 1, 25000 do
      lines[index] = string.format('{"msg":"m%d","status":%d}', index, index % 2 == 0 and 500 or 200)
    end
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    ws = assert(workspace.open({ bufnr = buf }))
    assert.is_true(vim.wait(10000, function()
      return not ws.loading
    end))
    workspace.timing = { tick_ns = 1e12, publish_ns = timing.publish_ns }
    store.timing = { tick_ns = 1e12 }
    -- the placeholder layout fits in one tick: keep this render running past it so the next apply supersedes it
    view.tick_ns = 0
    ws.state.filters = { "status=500" }
    ws:apply(function()
      done = done + 1
    end)
    view.tick_ns = view_tick_ns
    workspace.timing = vim.deepcopy(timing)
    store.timing = vim.deepcopy(store_timing)
    ws.state.filters = { "status=200" }
    ws:apply(function()
      done = done + 10
    end)
    assert.is_true(vim.wait(10000, function()
      return done >= 10
    end))
    vim.wait(100)
    assert.are.equal(10, done)
    ws:close()
  end)

  it("should mark the counts stale while a chunked scan runs", function()
    local lines = {}
    local buf, ws, marks

    for index = 1, 25000 do
      lines[index] = string.format('{"msg":"m%d","level":"%s"}', index, index % 5 == 0 and "ERROR" or "INFO")
    end
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    ws = assert(workspace.open({ bufnr = buf }))
    assert.is_true(vim.wait(10000, function()
      return not ws.loading and ws.rendered == ws.store.generation and not ws.sidebar.stale
    end))
    ws.sidebar:expand_field("level")
    workspace.timing = { tick_ns = 0, publish_ns = timing.publish_ns }
    store.timing = { tick_ns = 0 }

    ws:add_filter("level=ERROR")
    marks = vim.api.nvim_buf_get_extmarks(ws.sidebar.bufnr, -1, 0, -1, { details = true })

    assert.are_not.equal(ws.store.generation, ws.rendered)
    assert.are.equal("level=ERROR", vim.api.nvim_buf_get_lines(ws.sidebar.bufnr, 2, 3, false)[1])
    assert.is_truthy(vim.iter(marks):any(function(mark)
      return mark[4].hl_group == "JLogFieldStale"
    end))
    assert.is_truthy(vim.iter(marks):any(function(mark)
      return mark[4].virt_text ~= nil and mark[4].virt_text[1][1]:find("counting…", 1, true) ~= nil
    end))
    ws:close()
  end)

  it("should finish counting when the render is replaced before it ends", function()
    local lines = {}
    local buf, ws

    for index = 1, 25000 do
      lines[index] = string.format('{"msg":"m%d","status":%d}', index, index % 2 == 0 and 500 or 200)
    end
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    ws = assert(workspace.open({ bufnr = buf }))
    assert.is_true(vim.wait(10000, function()
      return not ws.loading and ws.rendered == ws.store.generation and not ws.sidebar.stale
    end))

    view.tick_ns = 0
    ws:add_filter("status=500")
    assert.is_true(vim.wait(10000, function()
      return ws.view.complete == false
    end, 1))
    ws.view:toggle_mode()
    view.tick_ns = view_tick_ns

    assert.is_true(vim.wait(10000, function()
      return ws.sidebar.stale == false
    end))
    assert.are.equal(12500, ws.store.counter.fields.status.counts["500"])
    ws:close()
  end)

  it("should render a filter before counting fields, then publish the counts", function()
    local lines = {}
    local buf, ws, stale_at_render, level

    for index = 1, 25000 do
      lines[index] = string.format('{"msg":"m%d","level":"%s"}', index, index % 5 == 0 and "ERROR" or "INFO")
    end
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    ws = assert(workspace.open({ bufnr = buf }))
    assert.is_true(vim.wait(10000, function()
      return not ws.loading and ws.rendered == ws.store.generation and not ws.sidebar.stale
    end))
    workspace.timing = { tick_ns = 0, publish_ns = timing.publish_ns }
    store.timing = { tick_ns = 0 }

    ws:add_filter("level=ERROR")
    assert.is_true(vim.wait(10000, function()
      return ws.rendered == ws.store.generation
    end, 1))
    stale_at_render = ws.sidebar.stale
    assert.is_true(vim.wait(10000, function()
      return ws.sidebar.stale == false
    end))

    assert.is_true(stale_at_render)
    for _, facet in ipairs(ws.sidebar.facets) do
      if facet.name == "level" then
        level = facet
      end
    end
    assert.are.same({ value = "ERROR", count = 5000 }, level.top[1])
    assert.are.equal(1, level.distinct)
    ws:close()
  end)

  describe("chunked jsonl loading", function()
    local sizes = vim.deepcopy(workspace.load_sizes)

    after_each(function()
      workspace.load_sizes = sizes
    end)

    it("should load every entry in order, with continuation lines across chunk boundaries", function()
      config.setup({ view = { sort = "asc" } })
      local lines = {}
      local buf, ws, view_lines

      for index = 1, 23 do
        lines[#lines + 1] = string.format('{"msg":"m%d","level":"INFO"}', index)
        if index % 5 == 0 then
          lines[#lines + 1] = "  at frame " .. index
        end
      end
      buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      -- chunks of 3 lines split entries from their continuation lines
      workspace.load_sizes = { first = 4, chunk = 3 }

      ws = assert(workspace.open({ bufnr = buf }))
      assert.is_true(ws.loading)
      assert.is_true(#ws.entries < 23)
      assert.is_true(vim.wait(2000, function()
        return not ws.loading
      end))

      assert.are.equal(23, #ws.entries)
      for index, entry in ipairs(ws.entries) do
        assert.is_truthy(entry.body:find('"m' .. index .. '"', 1, true))
        assert.are.equal(index % 5 == 0 and 1 or nil, entry.cont and #entry.cont)
      end
      assert.is_true(vim.wait(2000, function()
        return ws.rendered == ws.store.generation
      end))
      view_lines = vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false)
      assert.are.equal(#lines, #view_lines)
      assert.is_truthy(view_lines[#view_lines]:find("m23", 1, true))
    end)

    it("should show fields in the sidebar as they are found while loading", function()
      local lines = {}
      local buf, ws, header_marks
      local partial = {}

      for index = 1, 30 do
        lines[index] = index < 20 and string.format('{"msg":"m%d"}', index)
          or string.format('{"msg":"m%d","late":"x"}', index)
      end
      buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      workspace.load_sizes = { first = 4, chunk = 2 }
      workspace.timing = { tick_ns = 0, publish_ns = 0 }
      store.timing = { tick_ns = 0 }

      ws = assert(workspace.open({ bufnr = buf }))
      local render = ws.sidebar.render
      ws.sidebar.render = function(self, progress)
        if progress then
          partial[#partial + 1] = vim.tbl_map(function(facet)
            return facet.name
          end, self.facets)
        end
        render(self, progress)
        if progress then
          header_marks = vim.api.nvim_buf_get_extmarks(self.bufnr, -1, 0, -1, { details = true })
        end
      end
      assert.is_true(vim.wait(2000, function()
        return not ws.loading and ws.rendered == ws.store.generation
      end))

      assert.is_true(#partial > 0)
      assert.is_truthy(vim.tbl_contains(partial[#partial], "late"))
      assert.is_truthy(vim.iter(header_marks):any(function(mark)
        return mark[4].virt_text and mark[4].virt_text[1][1]:find("loading", 1, true) ~= nil
      end))
      assert.are.equal(
        30,
        ws.sidebar.facets[vim.fn.index(
          vim.tbl_map(function(facet)
            return facet.name
          end, ws.sidebar.facets),
          "msg"
        ) + 1].distinct
      )
      assert.are.same(
        {},
        vim.tbl_filter(
          function(mark)
            return mark[4].virt_text ~= nil
          end,
          vim.api.nvim_buf_get_extmarks(
            ws.sidebar.bufnr,
            vim.api.nvim_get_namespaces()["jlog.sidebar"],
            0,
            -1,
            { details = true }
          )
        )
      )
      ws:close()
    end)

    it("should notify when loading takes more than one tick and when it is done", function()
      local notify = vim.notify
      local messages = {}
      local lines = {}
      local buf, ws

      for index = 1, 30 do
        lines[index] = string.format('{"msg":"m%d"}', index)
      end
      buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      workspace.load_sizes = { first = 4, chunk = 2 }
      workspace.timing = { tick_ns = 0, publish_ns = 0 }
      store.timing = { tick_ns = 0 }
      vim.notify = function(msg)
        if msg:find("load", 1, true) then
          messages[#messages + 1] = msg
        end
      end

      ws = assert(workspace.open({ bufnr = buf }))
      assert.is_true(vim.wait(2000, function()
        return not ws.loading
      end))
      vim.notify = notify
      assert.are.same({ "jlog: loading…", "jlog: loaded 30 entries" }, messages)
      ws:close()
    end)

    it("should count fields while loading instead of decoding every line again", function()
      local entry_model = require("jlog.parse.entry")
      local decode = entry_model.decode
      local lines = {}
      local buf, ws
      local decodes = 0

      for index = 1, 40 do
        lines[index] = string.format('{"msg":"m%d","level":"INFO"}', index)
      end
      buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      workspace.load_sizes = { first = 4, chunk = 3 }
      entry_model.decode = function(...)
        decodes = decodes + 1
        return decode(...)
      end

      ws = assert(workspace.open({ bufnr = buf }))
      local ok = vim.wait(2000, function()
        return not ws.loading and ws.rendered == ws.store.generation
      end)
      entry_model.decode = decode

      assert.is_true(ok)
      -- only the first slice's apply decodes; the rest was counted from the load's own decode
      assert.is_true(decodes <= 4, "decoded " .. decodes .. " times")
      for _, facet in ipairs(ws.sidebar.facets) do
        if facet.name == "msg" then
          assert.are.equal(40, facet.distinct)
        elseif facet.name == "level" then
          assert.are.same({ { value = "INFO", count = 40 } }, facet.top)
        end
      end
      ws:close()
    end)

    it("should stop loading when the workspace is closed", function()
      local lines = {}
      local buf, ws

      for index = 1, 50 do
        lines[index] = '{"msg":"m' .. index .. '"}'
      end
      buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      workspace.load_sizes = { first = 2, chunk = 2 }

      ws = assert(workspace.open({ bufnr = buf }))
      ws:close()
      vim.wait(100)
      assert.is_true(#ws.entries < 50)
    end)
  end)
  describe("chunked element loading", function()
    local sizes = vim.deepcopy(workspace.load_sizes)

    after_each(function()
      workspace.load_sizes = sizes
    end)

    local function write_loki(elements)
      local path = vim.fn.tempname() .. ".json"

      vim.fn.writefile({ vim.json.encode(elements) }, path)

      return path
    end

    it("should show a newest-first loki export before it is fully loaded", function()
      local gen = dofile("bench/gen.lua")
      -- the generator writes oldest first
      local elements = vim.fn.reverse(vim.json.decode(gen.loki_text(3000)))
      local path = write_loki(elements)
      local ws

      workspace.load_sizes = { first = 50, chunk = 50 }
      ws = assert(workspace.open({ path = path }))

      assert.is_true(ws.loading)
      assert.is_true(ws.stored_newest_first)
      assert.is_false(ws.state.reverse)
      assert.are.equal(elements[1].timestamp, ws.entries[1].ts)
      assert.are.equal(1, ws.view.items[1].idx)
      assert.is_true(vim.wait(5000, function()
        return not ws.loading and ws.rendered == ws.store.generation
      end))
      assert.are.equal(3000, #ws.entries)
      assert.are.equal(1, ws.view.items[1].idx)
      assert.are.equal(elements[3000].timestamp, ws.entries[3000].ts)
      vim.fn.delete(path)
    end)

    it("should keep file order for equal timestamps and sort an unordered export without blocking", function()
      local elements = {}
      local stamps = { "30", "10", "20", "10", "30", "5", "20", "10" }
      local path, ws, previous

      config.setup({ view = { sort = "asc" } })
      for index, stamp in ipairs(stamps) do
        elements[index] = { line = '{"msg":"m' .. index .. '"}', timestamp = stamp, fields = { app = "a" } }
      end
      path = write_loki(elements)
      workspace.load_sizes = { first = 2, chunk = 2 }
      ws = assert(workspace.open({ path = path }))

      assert.is_true(ws.loading)
      assert.is_true(vim.wait(2000, function()
        return not ws.loading and ws.rendered == ws.store.generation
      end))
      assert.are.equal(#stamps, #ws.entries)
      assert.is_false(ws.stored_newest_first)
      for _, entry in ipairs(ws.entries) do
        if previous then
          assert.is_true(
            tonumber(previous.ts) < tonumber(entry.ts) or (previous.ts == entry.ts and previous.src < entry.src)
          )
        end
        previous = entry
      end
      assert.are.equal(1, ws.view.items[1].idx)
      vim.fn.delete(path)
    end)

    for _, case in ipairs({ { order = "unordered", step = 37 }, { order = "ordered", step = 0 } }) do
      it("should load a small " .. case.order .. " export read whole by the first slice and reload it", function()
        local elements = {}
        local path, ws

        for index = 1, 50 do
          elements[index] = {
            line = '{"msg":"m' .. index .. '"}',
            timestamp = tostring(1000 + (case.step > 0 and index * case.step % 50 or index)),
          }
        end
        path = write_loki(elements)
        ws = assert(workspace.open({ path = path }))
        assert.is_true(vim.wait(2000, function()
          return not ws.loading and ws.rendered == ws.store.generation
        end))
        assert.are.equal(50, #ws.entries)
        for index = 2, #ws.entries do
          assert.is_true(ws.entries[index - 1].ts < ws.entries[index].ts)
        end
        elements[51] = { line = '{"msg":"new"}', timestamp = "1051" }
        vim.fn.writefile({ vim.json.encode(elements) }, path)
        ws:reload()
        assert.is_true(vim.wait(2000, function()
          return not ws.loading and #ws.entries == 51
        end))
        ws:close()
        vim.fn.delete(path)
      end)
    end

    it("should sort a large unordered export across ticks", function()
      local elements = {}
      local path, ws, ok

      for index = 1, 9000 do
        -- 7919 is prime, so this visits every timestamp once, out of order
        elements[index] = { line = "plain " .. index, timestamp = tostring(1000000 + index * 7919 % 9000) }
      end
      path = write_loki(elements)
      workspace.timing = { tick_ns = 0, publish_ns = 0 }
      store.timing = { tick_ns = 0 }
      ws = assert(workspace.open({ path = path }))
      ok = vim.wait(10000, function()
        return not ws.loading and ws.rendered == ws.store.generation
      end)

      assert.is_true(ok)
      assert.are.equal(9000, #ws.entries)
      for index = 2, #ws.entries do
        assert.is_true(ws.entries[index - 1].ts < ws.entries[index].ts)
      end
      vim.fn.delete(path)
    end)

    local function capture_warnings()
      local warnings = {}
      local notify = vim.notify

      vim.notify = function(message, level)
        if level == vim.log.levels.WARN and message:find("broken JSON array", 1, true) then
          warnings[#warnings + 1] = message
        end
      end

      return warnings, function()
        vim.notify = notify
      end
    end

    local function loki_line(stamp)
      return vim.json.encode({ line = '{"msg":"m' .. stamp .. '"}', timestamp = tostring(stamp), fields = {} })
    end

    it("should open an export broken at element 3 with a warning and plain tail lines", function()
      local path = vim.fn.tempname() .. ".json"
      local warnings, restore = capture_warnings()
      local ws, err

      vim.fn.writefile({ "[" .. loki_line(20) .. "," .. loki_line(10) .. ',{"line":"cut', "more text", "" }, path)
      ws, err = workspace.open({ path = path })
      restore()

      assert.is_nil(err)
      assert.are.equal("loki", ws.format)
      assert.are.equal(1, #warnings)
      assert.are.equal(4, #ws.entries)
      assert.are.equal('{"line":"cut', ws.entries[3].raw)
      assert.are.equal("more text", ws.entries[4].raw)
      for _, entry in ipairs(ws.entries) do
        assert.is_nil(entry.cont)
      end
      ws:close()
      vim.fn.delete(path)
    end)

    it("should open and reload an export broken past the first slice with a warning", function()
      local path = vim.fn.tempname() .. ".json"
      local elements = {}
      local warnings, restore = capture_warnings()
      local ws, done

      for stamp = 9, 1, -1 do
        elements[#elements + 1] = loki_line(stamp)
      end
      vim.fn.writefile({ "[" .. table.concat(elements, ",") .. ',{"line', "tail one", "tail two" }, path)
      workspace.load_sizes = { first = 2, chunk = 2 }
      ws = assert(workspace.open({ path = path }))
      done = function()
        return not ws.loading and ws.rendered == ws.store.generation
      end

      assert.is_true(ws.loading)
      assert.is_true(vim.wait(2000, done))
      assert.are.equal(1, #warnings)
      assert.are.equal(12, #ws.entries)
      assert.are.same({ '{"line', "tail one", "tail two" }, {
        ws.entries[10].raw,
        ws.entries[11].raw,
        ws.entries[12].raw,
      })
      assert.is_nil(ws.entries[9].cont)
      assert.is_nil(ws.view.winbar_text:find("loading", 1, true))

      table.insert(elements, 1, loki_line(10))
      vim.fn.writefile({ "[" .. table.concat(elements, ",") .. ',{"line', "tail one", "tail two" }, path)
      ws:reload()
      assert.is_true(vim.wait(2000, function()
        return #ws.entries == 13 and done()
      end))
      restore()

      assert.are.equal(2, #warnings)
      assert.are.equal("tail two", ws.entries[13].raw)
      assert.is_nil(ws.view.winbar_text:find("loading", 1, true))
      ws:close()
      vim.fn.delete(path)
    end)

    it("should group a newest-first export like the same logs stored oldest first", function()
      local logs = {
        '{"time":"2026-10-22T10:00:01Z","request_id":"A","status":200,"msg":"start"}',
        '{"time":"2026-10-22T10:00:02Z","request_id":"B","status":201,"msg":"other"}',
        '{"time":"2026-10-22T10:00:03Z","request_id":"A","status":500,"msg":"done"}',
        '{"time":"2026-10-22T10:00:04Z","request_id":"B","msg":"after"}',
      }
      local jsonl = vim.fn.tempname() .. ".jsonl"
      local loki = vim.fn.tempname() .. ".json"
      local elements = {}

      for index = #logs, 1, -1 do
        elements[#elements + 1] = { line = logs[index], timestamp = tostring(index), fields = {} }
      end
      vim.fn.writefile(logs, jsonl)
      vim.fn.writefile({ vim.json.encode(elements) }, loki)

      local function grouped(path)
        local ws = assert(workspace.open({ path = path }))
        local lines

        assert.is_true(vim.wait(2000, function()
          return not ws.loading and ws.rendered == ws.store.generation
        end))
        ws:set_group("request_id")
        assert.is_true(vim.wait(2000, function()
          return ws.rendered == ws.store.generation
        end))
        lines = vim.list_extend(header_texts(ws.view.bufnr), vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false))
        ws:close()

        return lines
      end

      for _, sort in ipairs({ "desc", "asc" }) do
        config.setup({ view = { sort = sort } })
        local expected = grouped(jsonl)

        assert.are.same(expected, grouped(loki))
        -- groups follow time like the entries do
        assert.are.equal(1, #vim.tbl_filter(function(line)
          return line:find("A  2 entries", 1, true) ~= nil
        end, expected))
        assert.is_truthy(expected[1]:find(sort == "desc" and "B" or "A", 1, true))
      end
      vim.fn.delete(jsonl)
      vim.fn.delete(loki)
    end)

    it("should load a plain json array in file order and rebuild it in chunks on reload", function()
      local lines = {}
      local path = vim.fn.tempname() .. ".json"
      local ws

      for index = 1, 9 do
        lines[index] = '{"msg":"m' .. index .. '"}'
      end
      vim.fn.writefile({ "[" .. table.concat(lines, ",") .. "]" }, path)
      workspace.load_sizes = { first = 2, chunk = 2 }
      ws = assert(workspace.open({ path = path }))

      assert.is_true(ws.loading)
      assert.is_false(ws.stored_newest_first)
      assert.is_true(ws.state.reverse)
      assert.is_true(vim.wait(2000, function()
        return not ws.loading and ws.rendered == ws.store.generation
      end))
      assert.are.equal(9, #ws.entries)
      assert.are.equal(9, ws.view.items[1].idx)

      table.insert(lines, '{"msg":"m10"}')
      vim.fn.writefile({ "[" .. table.concat(lines, ",") .. "]" }, path)
      ws:reload()
      assert.is_true(ws.loading)
      assert.is_true(vim.wait(2000, function()
        return not ws.loading and #ws.entries == 10 and ws.rendered == ws.store.generation
      end))
      assert.are.equal(10, ws.view.items[1].idx)
      vim.fn.delete(path)
    end)
  end)

  describe("threaded load", function()
    local chunk_bytes = parallel.chunk_bytes
    local min_bytes = parallel.min_bytes
    local line_reader = parallel.line_reader
    local run = workers.run
    local stall_ms = workers.stall_ms
    local path

    before_each(function()
      parallel.min_bytes = 0
      parallel.chunk_bytes = 4096
      path = vim.fn.tempname() .. ".jsonl"
      vim.fn.writefile(gen.nested_lines(20000), path)
    end)
    after_each(function()
      parallel.chunk_bytes = chunk_bytes
      parallel.min_bytes = min_bytes
      parallel.line_reader = line_reader
      workers.run = run
      workers.stall_ms = stall_ms
      workers.disabled = nil
      config.setup()
      vim.fn.delete(path)
    end)

    ---@param threaded boolean
    ---@return JLogEntry[]
    local function loaded_entries(threaded)
      local ws

      workers.disabled = not threaded or nil
      ws = assert(workspace.open({ path = path }))
      assert.is_true(vim.wait(10000, function()
        return not ws.loading and ws.indexing == nil
      end))
      ws:close()

      return ws.entries
    end

    ---Record the entries list each threaded reader appends to, in the order the readers are made.
    ---@return table[] lists
    local function spy_readers()
      local lists = {}

      parallel.line_reader = function(...)
        local read = line_reader(...)
        local slot = #lists + 1

        lists[slot] = false

        return function(entries, ...)
          lists[slot] = entries

          return read(entries, ...)
        end
      end

      return lists
    end

    ---Wait until no job runs, then a little longer, so a late result would have been appended.
    local function settle_jobs()
      assert.is_true(vim.wait(5000, function()
        return workers.in_flight() == 0
      end, 1))
      vim.wait(100)
    end

    it("should drop chunks in flight when the workspace closes", function()
      local lists = spy_readers()
      local ws = assert(workspace.open({ path = path }))
      local sizes

      assert.is_true(vim.wait(2000, function()
        return workers.in_flight() > 0
      end, 1))
      ws:close()
      sizes = vim.tbl_map(function(list)
        return list and #list
      end, lists)
      settle_jobs()

      assert.are.same(
        sizes,
        vim.tbl_map(function(list)
          return list and #list
        end, lists)
      )
    end)

    it("should not append a dropped page load to any page once its jobs return", function()
      local lists, ws, old, old_size, srcs_ok

      require("jlog").setup({ paging = { size = 6000, overlap = 2 } })
      lists = spy_readers()
      ws = assert(workspace.open({ path = path }))
      assert.is_true(vim.wait(5000, function()
        return lists[#lists] and workers.in_flight() > 0
      end, 1))
      old = lists[#lists]
      assert.is_true(ws:goto_page(2))
      old_size = #old
      assert.is_true(vim.wait(10000, function()
        return not ws.loading and ws.page == 2
      end))
      settle_jobs()

      assert.are.equal(old_size, #old)
      assert.are_not.equal(old, ws.entries)
      srcs_ok = true
      for index = 2, #ws.entries do
        srcs_ok = srcs_ok and ws.entries[index].src > ws.entries[index - 1].src
      end
      assert.is_true(srcs_ok)
      assert.are.equal(ws.pages:range(2).first_src, ws.entries[1].src)
      ws:close()
    end)

    it("should load a threaded page with the same entries as a main-thread page", function()
      local base = loaded_entries(false)
      local entries = loaded_entries(true)

      assert.are.equal(#base, #entries)
      for index, entry in ipairs(base) do
        assert.are.equal(entry.src, entries[index].src)
        assert.are.equal(entry.json_at, entries[index].json_at)
        assert.are.same(entry.cont, entries[index].cont)
      end
    end)
    it("should not fall back into a new page after a stalled load is replaced", function()
      local base, lists, ws, old, old_size

      require("jlog").setup({ paging = { size = 6000, overlap = 2 } })
      workers.disabled = true
      ws = assert(workspace.open({ path = path }))
      assert.is_true(ws:goto_page(2))
      assert.is_true(vim.wait(10000, function()
        return not ws.loading and ws.page == 2
      end))
      base = ws.entries
      ws:close()
      workers.disabled = nil

      workers.stall_ms = 200
      workers.run = function() end
      lists = spy_readers()
      ws = assert(workspace.open({ path = path }))
      assert.is_true(vim.wait(5000, function()
        return lists[#lists]
      end, 1))
      old = lists[#lists]
      assert.is_true(ws:goto_page(2))
      old_size = #old
      assert.is_true(vim.wait(5000, function()
        return not ws.loading and ws.page == 2
      end))
      vim.wait(400)

      assert.are.equal(old_size, #old)
      assert.are.equal(#base, #ws.entries)
      for index, entry in ipairs(base) do
        assert.are.equal(entry.src, ws.entries[index].src)
        assert.are.equal(entry.json_at, ws.entries[index].json_at)
        assert.are.same(entry.cont, ws.entries[index].cont)
      end
      ws:close()
    end)
  end)
end)
