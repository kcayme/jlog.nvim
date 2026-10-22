local config = require("jlog.config")
local workspace = require("jlog.workspace")

describe("workspace", function()
  before_each(function()
    config.setup({ auto_open = { enable = false } })
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

  it("should open plain text when forced", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "not json", "still not" })
    local ws = assert(workspace.open({ bufnr = buf, force = true }))
    assert.are.equal(2, #ws.entries)
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
end)
