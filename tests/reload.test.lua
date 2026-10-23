local workspace = require("jlog.workspace")

local function wait(cond)
  assert.is_true(vim.wait(2000, cond, 20))
end

describe("reload", function()
  local notify = vim.notify
  local path
  local ws

  before_each(function()
    require("jlog").setup()
    path = vim.fn.tempname() .. ".jsonl"
    vim.fn.writefile({ '{"msg":"a","level":"INFO"}', '{"msg":"b","level":"ERROR"}' }, path)
  end)

  after_each(function()
    vim.notify = notify
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

  it("should insert appended lines at the top of a newest-first workspace without a full apply", function()
    local generation

    ws = workspace.open({ path = path })
    wait(function()
      return ws.rendered == ws.generation
    end)
    generation = ws.generation
    vim.fn.writefile({ '{"msg":"c","level":"INFO"}' }, path, "a")
    wait(function()
      return #ws.entries == 3
    end)
    wait(function()
      return vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, 1, false)[1]:find("c", 1, true) ~= nil
    end)
    assert.are.equal(generation, ws.generation)
  end)

  it("should count entries appended while the sidebar is still counting", function()
    local timing = vim.deepcopy(workspace.timing)
    local lines = {}
    local generation, level

    for index = 1, 1000 do
      lines[index] = string.format('{"msg":"m%d","level":"ERROR"}', index)
    end
    vim.fn.writefile(lines, path)
    ws = workspace.open({ path = path })
    wait(function()
      return not ws.loading and ws.rendered == ws.generation and not ws.sidebar.stale
    end)
    workspace.timing = { tick_ns = 0, publish_ns = timing.publish_ns }
    ws:add_filter("level=ERROR")
    wait(function()
      return ws.rendered == ws.generation
    end)
    generation = ws.generation
    assert.is_not_nil(ws.counting)
    vim.fn.writefile({ '{"msg":"c","level":"ERROR"}' }, path, "a")
    ws:reload()
    wait(function()
      return not ws.sidebar.stale
    end)
    workspace.timing = timing

    assert.are.equal(generation, ws.generation)
    for _, facet in ipairs(ws.sidebar.facets) do
      if facet.name == "level" then
        level = facet
      end
    end
    assert.are.same({ value = "ERROR", count = 1001 }, level.top[1])
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

  it("should keep watching after the file is deleted and created again", function()
    local notified = 0

    ws = workspace.open({ path = path })
    vim.notify = function()
      notified = notified + 1
    end
    vim.fn.delete(path)
    vim.wait(400)
    vim.fn.writefile({ '{"msg":"x"}', '{"msg":"y"}', '{"msg":"z"}' }, path)
    wait(function()
      return #ws.entries == 3
    end)
    assert.are.equal(1, notified)
    assert.are.equal("x", ws.entries[1].raw:match('"msg":"(%a)"'))
    vim.fn.writefile({ '{"msg":"w"}' }, path, "a")
    wait(function()
      return #ws.entries == 4
    end)
  end)

  it("should show the new file after the log is rotated", function()
    local rotated = path .. ".1"

    ws = workspace.open({ path = path })
    vim.uv.fs_rename(path, rotated)
    vim.wait(400)
    vim.fn.writefile({ '{"msg":"new","level":"INFO"}' }, path)
    wait(function()
      return #ws.entries == 1
    end)
    assert.are.equal('{"msg":"new","level":"INFO"}', ws.entries[1].raw)
    vim.fn.writefile({ '{"msg":"next"}' }, path, "a")
    wait(function()
      return #ws.entries == 2
    end)
    vim.fn.delete(rotated)
  end)

  it("should rebuild a rewritten jsonl file in chunks and keep expanded entries", function()
    ws = workspace.open({ path = path })
    ws.state.expanded[2] = true
    vim.fn.writefile({ '{"msg":"new"}', '{"msg":"a","level":"INFO"}', '{"msg":"b","level":"ERROR"}' }, path)
    ws:reload()
    assert.is_true(ws.loading)
    assert.are.equal(2, #ws.entries)
    wait(function()
      return #ws.entries == 3 and not ws.loading
    end)
    assert.are.same({ [3] = true }, ws.state.expanded)
    vim.fn.writefile({ '{"msg":"c"}' }, path, "a")
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

  it("should show continuation lines appended to the last entry of a grouped view", function()
    ws = workspace.open({ path = path })
    ws:set_group("level")
    wait(function()
      return ws.rendered == ws.generation
    end)
    vim.fn.writefile({ "panic: boom", "goroutine 1 [running]:" }, path, "a")
    wait(function()
      return ws.entries[2].cont ~= nil and #ws.entries[2].cont == 2 and ws.rendered == ws.generation
    end)
    wait(function()
      return vim.tbl_contains(vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false), "panic: boom")
    end)
  end)

  it("should keep unsaved sidebar filter edits when lines are appended", function()
    local bufnr

    ws = workspace.open({ path = path })
    wait(function()
      return ws.rendered == ws.generation
    end)
    bufnr = ws.sidebar.bufnr
    vim.api.nvim_buf_set_lines(bufnr, 2, 2, false, { "level=ERROR" })
    vim.fn.writefile({ '{"msg":"c","level":"INFO"}' }, path, "a")
    wait(function()
      return #ws.entries == 3 and ws.rendered == ws.generation
    end)
    vim.wait(100)
    assert.are.equal("level=ERROR", vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1])
    assert.is_true(vim.bo[bufnr].modified)
  end)
end)
