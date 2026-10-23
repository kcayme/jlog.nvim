local config = require("jlog.config")
local workspace = require("jlog.workspace")

describe("workspace", function()
  before_each(function()
    config.setup()
  end)
  after_each(function()
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
    assert.is_truthy(lines[1]:find("^▾ r1"))
    assert.are.equal(5, #lines) -- header, panic entry, its 2 continuation lines, request completed
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

  it("should group, count and filter large numbers exactly", function()
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
    lines = vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false)
    assert.is_truthy(lines[1]:find("12345678…", 1, true))
    assert.are.equal(3, #vim.tbl_filter(function(line)
      return line:find("^▾") ~= nil
    end, lines))
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
    assert.are.equal("jsonl", ws.format)
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

  it("should apply in chunks and let a newer apply supersede an in-flight one", function()
    local lines = {}
    for i = 1, 25000 do
      lines[i] = string.format('{"msg":"m%d","status":%d}', i, i % 2 == 0 and 500 or 200)
    end
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    local ws = assert(workspace.open({ bufnr = buf }))
    local done = 0
    assert.is_true(vim.wait(10000, function()
      return not ws.loading
    end))
    ws.state.filters = { "status=500" }
    ws:apply(function()
      done = done + 1
    end)
    ws.state.filters = { "status=200", "msg~m1" }
    ws:apply(function()
      done = done + 10
    end)
    assert.is_true(vim.wait(10000, function()
      return done > 0
    end))
    assert.are.equal(10, done)
    assert.is_truthy(ws.view.winbar_text:find("/25000 ", 1, true))
    assert.is_truthy(vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, 1, false)[1]:find("^m1 "))
  end)

  describe("chunked jsonl loading", function()
    local sizes = vim.deepcopy(workspace.load_sizes)

    after_each(function()
      workspace.load_sizes = sizes
    end)

    it("should load every entry in order, with continuation lines across chunk boundaries", function()
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
        return ws.rendered == ws.generation
      end))
      view_lines = vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false)
      assert.are.equal(#lines, #view_lines)
      assert.is_truthy(view_lines[#view_lines]:find("m23", 1, true))
    end)

    it("should show fields in the sidebar as they are found while loading", function()
      local lines = {}
      local buf, ws, header_marks
      local timing = vim.deepcopy(workspace.timing)
      local partial = {}

      for index = 1, 30 do
        lines[index] = index < 20 and string.format('{"msg":"m%d"}', index)
          or string.format('{"msg":"m%d","late":"x"}', index)
      end
      buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      workspace.load_sizes = { first = 4, chunk = 2 }
      workspace.timing = { tick_ns = 0, publish_ns = 0 }

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
        return not ws.loading and ws.rendered == ws.generation
      end))
      workspace.timing = timing

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
        vim.tbl_filter(function(mark)
          return mark[4].virt_text ~= nil
        end, vim.api.nvim_buf_get_extmarks(ws.sidebar.bufnr, -1, 0, -1, { details = true }))
      )
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
        return not ws.loading and ws.rendered == ws.generation
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
end)
