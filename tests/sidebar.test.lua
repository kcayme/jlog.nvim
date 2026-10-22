describe("sidebar", function()
  local ws

  after_each(function()
    if ws then
      ws:close()
    end
  end)

  it("should apply edited filters on write and flag bad lines", function()
    require("jlog.config").setup({ auto_open = { enable = false } })
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

  it("should set the group from a field name", function()
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/loki.json", ":p") })
    ws.sidebar:cursor_to_value("request_id")
    vim.api.nvim_feedkeys("g", "x", false)
    assert.are.equal("request_id", ws.state.group)
  end)
end)
