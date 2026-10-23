describe(":JLog", function()
  before_each(function()
    require("jlog").setup()
  end)
  after_each(function()
    pcall(vim.cmd, "silent! tabonly")
  end)

  it("should add filters and set the group on the current workspace", function()
    vim.cmd("JLog tests/fixtures/app.jsonl")
    vim.cmd("JLog filter status>=500")
    vim.cmd("JLog group request_id")
    local ws = require("jlog.workspace").find(vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p"))
    assert.are.same({ "status>=500" }, ws.state.filters)
    assert.are.equal("request_id", ws.state.group)
    vim.cmd("JLog filter")
    assert.are.same({}, ws.state.filters)
  end)

  it("should keep spaces in a filter clause", function()
    vim.cmd("JLog tests/fixtures/app.jsonl")
    vim.cmd("JLog filter msg~request completed")
    local ws = require("jlog.workspace").find(vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p"))
    assert.are.same({ "msg~request completed" }, ws.state.filters)
    vim.cmd("JLog filter")
  end)

  it("should open the current buffer when given no arguments", function()
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.cmd("tabnew")
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "plain text" })
    vim.cmd("JLog")
    assert.is_truthy(vim.api.nvim_buf_get_name(0):find("^jlog://"))
    assert.is_truthy(vim.api.nvim_buf_is_valid(bufnr))
    vim.cmd("JLog close")
    assert.is_nil(vim.api.nvim_buf_get_name(0):find("^jlog://"))
  end)

  it("should open the raw source with :JLog raw", function()
    local path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p")
    vim.cmd("JLog " .. path)
    vim.cmd("JLog raw")
    assert.are.equal(path, vim.api.nvim_buf_get_name(0))
  end)

  it("should move to a page with :JLog page", function()
    local path = vim.fn.tempname() .. ".jsonl"
    local lines = {}
    local ws

    for index = 1, 35 do
      lines[index] = string.format('{"msg":"m%d"}', index)
    end
    vim.fn.writefile(lines, path)
    require("jlog").setup({ paging = { size = 10, overlap = 2 } })
    vim.cmd("JLog " .. path)
    ws = require("jlog.workspace").find(path)
    vim.cmd("JLog page 2")
    assert.is_true(vim.wait(2000, function()
      return ws.page == 2 and not ws.loading
    end, 20))
    ws:close()
    vim.fn.delete(path)
  end)

  it("should warn when the tab has no workspace", function()
    local original_notify = vim.notify
    local level
    vim.notify = function(_, lvl)
      level = lvl
    end
    vim.cmd("tabnew")
    vim.cmd("JLog filter status>=500")
    vim.notify = original_notify
    assert.are.equal(vim.log.levels.WARN, level)
  end)

  it("should complete subcommands, then field names", function()
    local commands = require("jlog.commands")
    vim.cmd("JLog tests/fixtures/app.jsonl")
    assert.are.same({ "filter" }, commands.complete("fil", "JLog fil"))
    assert.is_true(vim.tbl_contains(commands.complete("", "JLog group "), "request_id"))
    assert.are.same({ "status" }, commands.complete("sta", "JLog filter sta"))
  end)
end)
