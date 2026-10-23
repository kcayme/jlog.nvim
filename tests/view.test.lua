local view = require("jlog.ui.view")
local source = require("jlog.parse.source")
local opts = require("jlog.config").setup()

local function make_ws(text)
  return { entries = source.build(text, "jsonl"), opts = opts, state = { mode = "compact", expanded = {} } }
end
local function all(list)
  return vim.tbl_map(function(i)
    return { kind = "entry", idx = i }
  end, list)
end

describe("view", function()
  it("should render one line per entry plus continuation lines and map lines to items", function()
    local ws = make_ws('{"msg":"a"}\ntrace\n{"msg":"b"}')
    local v = view.new(ws)
    v:render(all({ 1, 2 }))
    assert.are.same({ "a", "trace", "b" }, vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false))
    assert.are.same({ 1, 1, 2 }, v.line_item)
    -- re-renders replace the whole buffer; undo must not keep copies of it
    assert.are.equal(-1, vim.bo[v.bufnr].undolevels)
  end)

  describe("chunked re-render", function()
    local tick_ns, trim_slice = view.tick_ns, view.trim_slice
    local function lines_of(count)
      local out = {}
      for i = 1, count do
        out[i] = string.format('{"msg":"m%d"}', i)
      end
      return table.concat(out, "\n")
    end
    local function render_and_wait(v, items)
      local done = false
      v:render(items, function()
        done = true
      end)
      assert.is_true(vim.wait(2000, function()
        return done
      end, 1))
    end

    before_each(function()
      -- every batch ends its tick, and stale lines go 7 at a time, so both span many ticks
      view.tick_ns, view.trim_slice = 0, 7
    end)
    after_each(function()
      view.tick_ns, view.trim_slice = tick_ns, trim_slice
    end)

    it("should drop the old lines when re-rendering fewer items", function()
      local v = view.new(make_ws(lines_of(300)))
      local ids = {}
      for i = 1, 300 do
        ids[i] = i
      end
      render_and_wait(v, all(ids))
      assert.are.equal(300, vim.api.nvim_buf_line_count(v.bufnr))

      render_and_wait(v, all({ 5, 6, 7 }))
      assert.are.same({ "m5", "m6", "m7" }, vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false))
      assert.are.same({ 1, 2, 3 }, v.line_item)

      render_and_wait(v, {})
      assert.are.same({ "" }, vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false))
    end)

    it("should keep lines and maps consistent when a newer render supersedes a chunked one", function()
      local v = view.new(make_ws(lines_of(300)))
      local ids = {}
      for i = 1, 300 do
        ids[i] = i
      end
      render_and_wait(v, all(ids))
      v:render(all(vim.list_slice(ids, 1, 200)))
      render_and_wait(v, all({ 9, 10 }))
      vim.wait(50)
      assert.are.same({ "m9", "m10" }, vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false))
      assert.are.equal(#v.line_item, vim.api.nvim_buf_line_count(v.bufnr))
    end)
  end)

  it("should expand and collapse the entry under the cursor in place", function()
    local ws = make_ws('{"msg":"a","n":1}\n{"msg":"b"}')
    local v = view.new(ws)
    v:render(all({ 1, 2 }))
    vim.api.nvim_win_set_buf(0, v.bufnr)
    v:goto_entry(1)
    v:toggle_entry()
    assert.are.equal("{", vim.api.nvim_buf_get_lines(v.bufnr, 0, 1, false)[1])
    assert.are.equal(1, v:entry_at_cursor())
    v:toggle_entry()
    assert.are.equal(2, vim.api.nvim_buf_line_count(v.bufnr))
  end)

  it("should render an empty item list without error", function()
    local v = view.new(make_ws(""))
    v:render({})
    assert.are.same({ "" }, vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false))
  end)

  it("should fold group headers", function()
    local ws = make_ws('{"msg":"a"}')
    local v = view.new(ws)
    v:render({ { kind = "header", group = { label = "g", idxs = { 1 } } }, { kind = "entry", idx = 1 } })
    vim.api.nvim_win_set_buf(0, v.bufnr)
    assert.are.equal(">1", view.foldexpr(1))
    assert.are.equal("1", view.foldexpr(2))
  end)

  it("should fold group headers by hand in large views", function()
    local ws = make_ws('{"msg":"a"}\n{"msg":"b"}\n{"msg":"c"}')
    local v = view.new(ws)
    local limit = view.fold_expr_limit

    view.fold_expr_limit = 0
    vim.api.nvim_win_set_buf(0, v.bufnr)
    v:render({
      { kind = "entry", idx = 3 },
      { kind = "header", group = { label = "g", idxs = { 1 } } },
      { kind = "entry", idx = 1 },
      { kind = "header", group = { label = "h", idxs = { 2 } } },
      { kind = "entry", idx = 2 },
    })
    view.fold_expr_limit = limit
    assert.are.equal("manual", vim.wo.foldmethod)
    assert.are.same({ 0, 1, 1, 1, 1 }, vim.tbl_map(vim.fn.foldlevel, { 1, 2, 3, 4, 5 }))
    assert.are.equal(-1, vim.fn.foldclosed(2))
    vim.cmd("2foldclose")
    assert.are.same({ 2, 3 }, { vim.fn.foldclosed(3), vim.fn.foldclosedend(2) })
    v:render({ { kind = "entry", idx = 1 } })
    assert.are.equal(0, vim.fn.foldlevel(1))
  end)

  it("should map configured keys with descriptions and skip disabled ones", function()
    local ws = make_ws('{"msg":"a"}')
    ws.opts = require("jlog.config").setup({ keymaps = { reverse = false } })
    local v = view.new(ws)
    local maps = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(v.bufnr, "n")) do
      maps[map.lhs] = map.desc
    end
    assert.are.equal("jlog: toggle_entry", maps["<Tab>"])
    assert.is_nil(maps["R"])
  end)

  it("should restore the winbar when a chunked render is replaced by a small one", function()
    local lines = {}
    for index = 1, 12000 do
      lines[index] = '{"msg":"m' .. index .. '"}'
    end
    local v = view.new(make_ws(table.concat(lines, "\n")))
    vim.api.nvim_win_set_buf(0, v.bufnr)
    v:set_winbar("jlog · test")
    local items = {}
    for index = 1, 12000 do
      items[index] = { kind = "entry", idx = index }
    end
    v:render(items)
    v:render(all({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }))
    assert.are.equal("%#JLogWinbar#jlog · test", vim.wo.winbar)
  end)

  it("should leave user highlight overrides alone", function()
    vim.api.nvim_set_hl(0, "JLogLevelError", { fg = "#ff0000" })
    require("jlog.ui.highlights").setup()
    assert.are.equal(0xff0000, vim.api.nvim_get_hl(0, { name = "JLogLevelError" }).fg)
  end)
end)
