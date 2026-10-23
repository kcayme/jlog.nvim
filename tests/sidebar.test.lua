describe("sidebar", function()
  local ws

  after_each(function()
    if ws then
      ws:close()
    end
  end)

  it("should apply edited filters on write and flag bad lines", function()
    require("jlog.config").setup()
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
    local sb = ws.sidebar.bufnr
    vim.api.nvim_buf_set_lines(sb, 1, 1, false, { "level=ERROR", 'msg="oops' })
    vim.api.nvim_buf_call(sb, function()
      vim.cmd("write")
    end)
    assert.are.same({ "level=ERROR" }, ws.state.filters)
    assert.are.equal(1, #vim.diagnostic.get(sb))
  end)

  it("should add a filter from a facet value", function()
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/loki.json", ":p") })
    -- place cursor on the expanded "status" facet's "200" value line, press the add_filter key
    ws.sidebar:expand_field("status")
    ws.sidebar:cursor_to_value("status", "200")
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert.are.same({ "status=200" }, ws.state.filters)
  end)

  it("should keep a bad filter line visible until it is edited", function()
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/loki.json", ":p") })
    local sb = ws.sidebar.bufnr
    vim.api.nvim_buf_set_lines(sb, 1, 1, false, { 'msg="oops' })
    vim.api.nvim_buf_call(sb, function()
      vim.cmd("write")
    end)
    ws:add_filter("status=200")
    assert.are.same({ "FILTERS", "status=200", 'msg="oops' }, vim.api.nvim_buf_get_lines(sb, 0, 3, false))
    assert.are.equal(2, vim.diagnostic.get(sb)[1].lnum)
    assert.is_false(vim.bo[sb].modified)
  end)

  it("should not turn the group into a filter when the GROUP BY header is deleted", function()
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
    ws:add_filter("level=INFO")
    ws:set_group("request_id")
    local sb = ws.sidebar.bufnr
    for row, line in ipairs(vim.api.nvim_buf_get_lines(sb, 0, -1, false)) do
      if line == "GROUP BY" then
        vim.api.nvim_buf_set_lines(sb, row - 1, row, false, {})
        break
      end
    end
    vim.api.nvim_buf_call(sb, function()
      vim.cmd("write")
    end)
    assert.are.same({ "level=INFO" }, ws.state.filters)
    assert.is_nil(ws.state.group)
  end)

  it("should quote and escape a facet value ending in a backslash", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '{"msg":"a","p":"C:\\\\dir x\\\\"}', '{"msg":"b","p":"y"}' })
    ws = assert(require("jlog.workspace").open({ bufnr = buf }))
    ws.sidebar:expand_field("p")
    ws.sidebar:cursor_to_value("p", "C:\\dir x\\")
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert.are.same({ 'p="C:\\\\dir x\\\\"' }, ws.state.filters)
    assert.is_truthy(ws.view.winbar_text:find(" 1/2 ", 1, true))
  end)

  it("should add a filter from a facet value that holds a newline", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '{"msg":"a","p":"x\\ny"}', '{"msg":"b","p":"y"}' })
    ws = assert(require("jlog.workspace").open({ bufnr = buf }))
    ws.sidebar:expand_field("p")
    ws.sidebar:cursor_to_value("p", "x\ny")
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert.are.same({ 'p="x\\ny"' }, ws.state.filters)
    assert.is_truthy(ws.view.winbar_text:find(" 1/2 ", 1, true))
    ws:set_group("p")
  end)

  it("should show, filter and group by a field name that holds a newline", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '{"msg":"a","k\\ney":"x"}', '{"msg":"b","k\\ney":"y"}' })
    ws = assert(require("jlog.workspace").open({ bufnr = buf }))
    assert.is_truthy(vim.wait(2000, function()
      return ws.rendered == ws.generation
    end, 10))
    ws.sidebar:expand_field("k\ney")
    ws.sidebar:cursor_to_value("k\ney", "x")
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert.are.same({ "k\\ney=x" }, ws.state.filters)
    assert.is_truthy(ws.view.winbar_text:find(" 1/2 ", 1, true))
    ws.sidebar:cursor_to_value("k\ney")
    vim.api.nvim_feedkeys("g", "x", false)
    assert.are.equal("k\\ney", ws.state.group)
    assert.is_truthy(vim.wait(2000, function()
      return ws.rendered == ws.generation
    end, 10))
    assert.is_truthy(vim.tbl_contains(vim.api.nvim_buf_get_lines(ws.sidebar.bufnr, 0, -1, false), "k\\ney"))
  end)

  it("should fit long field values to the sidebar width and keep their counts", function()
    local long = string.rep("x", 100)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      '{"msg":"a","path":"' .. long .. '","event":"' .. long .. '"}',
      '{"msg":"b","path":"/short","event":"' .. long .. '"}',
    })
    ws = assert(require("jlog.workspace").open({ bufnr = buf }))
    assert.is_truthy(vim.wait(2000, function()
      return ws.rendered == ws.generation
    end, 10))
    ws.sidebar:expand_field("path")
    local winid = vim.fn.bufwinid(ws.sidebar.bufnr)
    local width = vim.api.nvim_win_get_width(winid) - vim.fn.getwininfo(winid)[1].textoff
    local lines = vim.api.nvim_buf_get_lines(ws.sidebar.bufnr, 0, -1, false)
    for _, line in ipairs(lines) do
      assert.is_true(vim.fn.strdisplaywidth(line) <= width, line)
    end
    assert.is_truthy(vim.tbl_contains(lines, "  " .. string.rep("x", width - 7) .. "… (1)"))
    assert.is_truthy(vim.tbl_contains(lines, "▸ event           " .. long:sub(1, width - 23) .. "… (2)"))
    ws.sidebar:cursor_to_value("path", long)
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert.are.same({ "path=" .. long }, ws.state.filters)
  end)

  it("should refit field lines when the sidebar is resized, unless it has unsaved edits", function()
    local long = string.rep("x", 100)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '{"msg":"a","path":"' .. long .. '"}', '{"msg":"b","path":"y"}' })
    ws = assert(require("jlog.workspace").open({ bufnr = buf }))
    assert.is_truthy(vim.wait(2000, function()
      return ws.rendered == ws.generation
    end, 10))
    ws.sidebar:expand_field("path")
    local winid = vim.fn.bufwinid(ws.sidebar.bufnr)
    local function longest()
      local max = 0
      for _, line in ipairs(vim.api.nvim_buf_get_lines(ws.sidebar.bufnr, 0, -1, false)) do
        max = math.max(max, vim.fn.strdisplaywidth(line))
      end
      return max
    end
    local before = longest()

    -- headless nvim never redraws, so it never fires WinResized itself
    vim.api.nvim_win_set_width(winid, 60)
    vim.api.nvim_exec_autocmds("WinResized", {})
    assert.is_true(longest() > before)
    assert.is_true(longest() <= 60)

    vim.api.nvim_buf_set_lines(ws.sidebar.bufnr, 1, 1, false, { "level=ERROR" })
    vim.api.nvim_win_set_width(winid, 50)
    vim.api.nvim_exec_autocmds("WinResized", {})
    assert.are.equal("level=ERROR", vim.api.nvim_buf_get_lines(ws.sidebar.bufnr, 1, 2, false)[1])
  end)

  it("should keep the cursor on the same field when new fields are rendered above it", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '{"msg":"a","path":"/x"}', '{"msg":"b","path":"/y"}' })
    ws = assert(require("jlog.workspace").open({ bufnr = buf }))
    assert.is_truthy(vim.wait(2000, function()
      return ws.rendered == ws.generation
    end, 10))
    ws.sidebar:expand_field("path")
    ws.sidebar:cursor_to_value("path", "/y")
    table.insert(
      ws.sidebar.facets,
      1,
      { name = "aaa", distinct = 1, capped = false, top = { { value = "1", count = 2 } } }
    )
    ws.sidebar:render("loading 50%")
    assert.are.same({ name = "path", value = "/y" }, ws.sidebar:row_at_cursor())
  end)

  it("should keep acting on stale rows", function()
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/loki.json", ":p") })
    ws.sidebar:expand_field("status")
    ws.sidebar.stale = true
    ws.sidebar:render()
    ws.sidebar:cursor_to_value("status", "200")
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert.are.same({ "status=200" }, ws.state.filters)
  end)

  it("should mark stale counts and show the counting marker", function()
    local marks

    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/loki.json", ":p") })
    ws.sidebar:expand_field("status")
    ws.sidebar.stale = true
    ws.sidebar:render()
    marks = vim.api.nvim_buf_get_extmarks(ws.sidebar.bufnr, -1, 0, -1, { details = true })
    assert.is_truthy(vim.iter(marks):any(function(mark)
      return mark[4].virt_text ~= nil and mark[4].virt_text[1][1]:find("counting…", 1, true) ~= nil
    end))
    assert.is_truthy(vim.iter(marks):any(function(mark)
      return mark[4].hl_group == "JLogFieldStale"
    end))
    assert.is_falsy(vim.iter(marks):any(function(mark)
      return mark[4].hl_group == "JLogFieldCount"
    end))
  end)

  it("should set the group from a field name", function()
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/loki.json", ":p") })
    ws.sidebar:cursor_to_value("request_id")
    vim.api.nvim_feedkeys("g", "x", false)
    assert.are.equal("request_id", ws.state.group)
  end)
end)
