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

  it("should prepend entries and keep the maps consistent", function()
    local v = view.new(make_ws('{"msg":"m1"}\n{"msg":"m2"}\n{"msg":"m3"}'))
    v.ws.state.reverse = true
    v:render(all({ 2, 1 }))
    v:prepend({ 3 })
    assert.are.same({ "m3", "m2", "m1" }, vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false))
    assert.are.same({ 1, 2, 3 }, v.line_item)
    assert.are.equal(3, v.items[1].idx)
    assert.are.same({ 1, 2, 3 }, v.item_line)
    assert.are.same({ [3] = 1, [2] = 2, [1] = 3 }, v.entry_item)
  end)

  it("should re-render the newest entry in place when it gains continuation lines, then prepend", function()
    local v = view.new(make_ws('{"msg":"m1"}\n{"msg":"m2"}\n{"msg":"m3"}'))
    local entries = v.ws.entries
    local third = table.remove(entries)

    v.ws.state.reverse = true
    v:render(all({ 2, 1 }))
    entries[2].cont = { "trace" }
    entries[3] = third
    v:prepend({ 3 }, 2)
    assert.are.same({ "m3", "m2", "trace", "m1" }, vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false))
    assert.are.same({ 1, 2, 2, 3 }, v.line_item)
    assert.are.same({ 1, 2, 4 }, v.item_line)
    assert.are.same({ [3] = 1, [2] = 2, [1] = 3 }, v.entry_item)
  end)

  describe("chunked re-render", function()
    local tick_ns, trim_slice, read_slice = view.tick_ns, view.trim_slice, view.read_slice
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
      -- every batch ends its tick, and old lines are read and trimmed 7 at a time, so all of it spans many ticks
      view.tick_ns, view.trim_slice, view.read_slice = 0, 7, 7
    end)
    after_each(function()
      view.tick_ns, view.trim_slice, view.read_slice = tick_ns, trim_slice, read_slice
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

    it("should reuse the text of entries already in the view instead of rendering them again", function()
      local render = require("jlog.ui.render")
      local compact = render.compact
      local calls = 0
      local ws = make_ws(lines_of(300) .. "\n  at frame")
      local v = view.new(ws)
      local ids = {}
      for i = 1, 300 do
        ids[i] = i
      end
      render_and_wait(v, all(ids))
      render.compact = function(...)
        calls = calls + 1
        return compact(...)
      end

      -- old order (a narrowing filter) with a header and a continuation line; gaps up to trim_slice are skipped
      view.trim_slice = 1000
      render_and_wait(
        v,
        { { kind = "header", group = { label = "g", idxs = { 2, 300 } } }, unpack(all({ 2, 150, 300 })) }
      )
      render.compact = compact
      assert.are.equal(0, calls)
      assert.are.same(
        { "m2", "m150", "m300", "  at frame" },
        vim.list_slice(vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false), 2)
      )
      assert.are.same({ 1, 2, 3, 4, 4 }, v.line_item)
    end)

    it("should render entries again when the new order passes them (grouped or reversed)", function()
      local render = require("jlog.ui.render")
      local compact = render.compact
      local calls = 0
      local v = view.new(make_ws(lines_of(300)))
      local ids = {}
      for i = 1, 300 do
        ids[i] = i
      end
      render_and_wait(v, all(ids))
      render.compact = function(...)
        calls = calls + 1
        return compact(...)
      end

      render_and_wait(v, all({ 300, 2, 1 }))
      render.compact = compact
      assert.are.equal(2, calls)
      assert.are.same({ "m300", "m2", "m1" }, vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false))
      assert.are.equal(#v.line_item, vim.api.nvim_buf_line_count(v.bufnr))
    end)

    it("should render normally entries too far below the reused ones", function()
      local v = view.new(make_ws(lines_of(300)))
      local ids = {}
      for i = 1, 300 do
        ids[i] = i
      end
      render_and_wait(v, all(ids))

      render_and_wait(v, all({ 1, 200, 201 }))

      assert.are.same({ "m1", "m200", "m201" }, vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false))
      assert.are.equal(#v.line_item, vim.api.nvim_buf_line_count(v.bufnr))
    end)

    it("should render again entries that are expanded now or whose entries were replaced", function()
      local render = require("jlog.ui.render")
      local compact = render.compact
      local calls = 0
      local ws = make_ws(lines_of(20))
      local v = view.new(ws)
      local ids = {}
      for i = 1, 20 do
        ids[i] = i
      end
      render_and_wait(v, all(ids))
      ws.state.expanded[3] = true
      render_and_wait(v, all({ 3, 4 }))
      assert.are.same("{", vim.api.nvim_buf_get_lines(v.bufnr, 0, 1, false)[1])
      assert.are.equal("m4", vim.api.nvim_buf_get_lines(v.bufnr, -2, -1, false)[1])

      ws.state.expanded = {}
      ws.entries = source.build((lines_of(20):gsub('"m(%d)', '"n%1')), "jsonl")
      render.compact = function(...)
        calls = calls + 1
        return compact(...)
      end
      render_and_wait(v, all({ 1, 2 }))
      render.compact = compact
      assert.are.equal(2, calls)
      assert.are.same({ "n1", "n2" }, vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false))
    end)

    it("should render compact lines again when the whole view toggles back from expanded", function()
      local v = view.new(make_ws(lines_of(3)))
      render_and_wait(v, all({ 1, 2, 3 }))
      v:toggle_mode()
      assert.is_true(vim.wait(2000, function()
        return vim.api.nvim_buf_get_lines(v.bufnr, 0, 1, false)[1] == "{"
      end, 1))
      v:toggle_mode()
      assert.is_true(vim.wait(2000, function()
        return vim.deep_equal({ "m1", "m2", "m3" }, vim.api.nvim_buf_get_lines(v.bufnr, 0, -1, false))
      end, 1))
      assert.are.equal(#v.line_item, vim.api.nvim_buf_line_count(v.bufnr))
    end)

    it("should notify when a render runs past the first screen and when it is done", function()
      local notify = vim.notify
      local messages = {}
      local v = view.new(make_ws(lines_of(300)))
      local ids = {}

      for i = 1, 300 do
        ids[i] = i
      end
      vim.notify = function(msg)
        messages[#messages + 1] = msg
      end
      render_and_wait(v, all({ 1 }))
      render_and_wait(v, all(ids))
      vim.notify = notify
      assert.are.same({ "jlog: rendering…", "jlog: rendering done" }, messages)
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
