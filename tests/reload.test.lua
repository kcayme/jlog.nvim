local workspace = require("jlog.workspace")

local function wait(cond)
  assert.is_true(vim.wait(2000, cond, 20))
end

describe("reload", function()
  local path
  local ws

  before_each(function()
    require("jlog").setup({ auto_open = { enable = false } })
    path = vim.fn.tempname() .. ".jsonl"
    vim.fn.writefile({ '{"msg":"a","level":"INFO"}', '{"msg":"b","level":"ERROR"}' }, path)
  end)

  after_each(function()
    if ws then
      ws:close()
      ws = nil
    end
    vim.fn.delete(path)
  end)

  it("should append new lines and keep filters", function()
    ws = workspace.open({ path = path })
    ws:add_filter("level=ERROR")
    vim.fn.writefile({ '{"msg":"c","level":"ERROR"}' }, path, "a")
    wait(function()
      return #ws.entries == 3
    end)
    assert.are.same({ "level=ERROR" }, ws.state.filters)
    assert.are.equal(2, #vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false))
  end)

  it("should rebuild after an atomic rename save and keep the cursor entry", function()
    local tmp = path .. ".tmp"

    ws = workspace.open({ path = path })
    vim.api.nvim_set_current_win(vim.fn.bufwinid(ws.view.bufnr))
    ws.view:goto_entry(2)
    vim.fn.writefile({ '{"msg":"z"}', '{"msg":"a","level":"INFO"}', '{"msg":"b","level":"ERROR"}' }, tmp)
    vim.uv.fs_rename(tmp, path)
    wait(function()
      return #ws.entries == 3
    end)
    wait(function()
      return ws.view:entry_at_cursor() == 3
    end)
    vim.fn.writefile({ '{"msg":"y"}' }, path, "a")
    wait(function()
      return #ws.entries == 4
    end)
  end)

  it("should hold back a partial last line until it is completed", function()
    local fd

    ws = workspace.open({ path = path })
    fd = io.open(path, "a")
    fd:write('{"msg":"c"')
    fd:close()
    ws:reload()
    assert.are.equal(2, #ws.entries)

    fd = io.open(path, "a")
    fd:write(',"level":"WARN"}\n')
    fd:close()
    wait(function()
      return #ws.entries == 3
    end)
    assert.are.equal(3, #vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false))
  end)

  it("should apply appended entries to a grouped view", function()
    ws = workspace.open({ path = path })
    ws:set_group("level")
    vim.fn.writefile({ '{"msg":"c","level":"INFO"}' }, path, "a")
    wait(function()
      return #ws.entries == 3
    end)
    wait(function()
      return #vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false) == 5
    end)
  end)
end)
