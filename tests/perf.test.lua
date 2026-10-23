local gen = dofile("bench/gen.lua")
local source = require("jlog.parse.source")
local filter = require("jlog.query.filter")
local group = require("jlog.query.group")
local render = require("jlog.ui.render")
local entry_model = require("jlog.parse.entry")
local workspace = require("jlog.workspace")

local COUNT = 100000

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

if vim.env.JLOG_PERF ~= "1" then
  return
end

describe("perf (100k lines)", function()
  local opts
  local path
  local ws
  local text
  local entries
  local baseline
  local input_bytes

  before_each(function()
    if input_bytes then
      return
    end

    require("jlog").setup()
    opts = require("jlog.config").options
    -- LuaJIT interns strings, so the baseline is taken before the input exists: the input text is counted too
    collectgarbage("collect")
    baseline = collectgarbage("count")
    text = table.concat(gen.jsonl_lines(COUNT), "\n") .. "\n"
    input_bytes = #text
  end)

  after_each(function()
    if ws then
      ws:close()
      ws = nil
    end
    if path then
      vim.fn.delete(path)
      path = nil
    end
  end)

  it("should parse, render, filter and stay within memory budgets", function()
    local start, elapsed, pred, entry, decoded, matched, items, ctx

    start = now_ms()
    entries = source.build(text, "jsonl")
    elapsed = now_ms() - start
    print(string.format("source.build: %.0fms (budget 1000)", elapsed))
    assert.is_true(elapsed < 1000)

    start = now_ms()
    for _, item in ipairs(entries) do
      render.compact(item, opts, true)
    end
    elapsed = now_ms() - start
    print(string.format("render.compact x%d: %.0fms (budget 1500)", #entries, elapsed))
    assert.is_true(elapsed < 1500)

    -- the workspace drops the source text after parsing, so only the entries are counted
    text = nil
    collectgarbage("collect")
    print(
      string.format(
        "lua memory growth: %.1f MB for %.1f MB input",
        (collectgarbage("count") - baseline) / 1024,
        input_bytes / 1048576
      )
    )
    assert.is_true(collectgarbage("count") - baseline < 3 * input_bytes / 1024)

    -- direct compile + build, not the chunked apply() pipeline
    matched = {}
    ctx = {
      get = function(path)
        return entry_model.get(entry, decoded, path, opts)
      end,
    }
    start = now_ms()
    pred = filter.compile({ "status>=500 path~licence" })
    for index = 1, #entries do
      entry = entries[index]
      decoded = entry_model.decode(entry)
      ctx.raw = entry_model.key(entry)
      matched[index] = pred(ctx)
    end
    items = group.build(#entries, {
      pred = function(index)
        return matched[index]
      end,
      get = function() end,
    })
    elapsed = now_ms() - start
    -- spec 5.4 budgets filter/group apply at 1000ms; the 300ms in the plan has too little headroom to be stable
    print(string.format("filter.compile + group.build (%d shown): %.0fms (budget 1000)", #items, elapsed))
    assert.is_true(elapsed < 1000)
  end)

  it("should show the first screen before the whole log is parsed", function()
    local start, elapsed

    path = vim.fn.tempname() .. ".jsonl"
    vim.fn.writefile(gen.jsonl_lines(COUNT), path)
    start = now_ms()
    ws = workspace.open({ path = path })
    elapsed = now_ms() - start
    print(string.format("workspace.open -> first lines in view: %.0fms (budget 300)", elapsed))
    assert.is_true(#vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false) > 0)
    assert.is_true(ws.loading)
    assert.is_true(elapsed < 300)
  end)

  it("should keep every main-loop tick short while a filter or group applies", function()
    local monitor = vim.uv.new_timer()
    local worst, last

    ---Run `action`, wait for its apply to render, and return the longest gap between ticks meanwhile.
    local function worst_tick(action)
      worst, last = 0, vim.uv.hrtime()
      monitor:start(0, 1, function()
        local now = vim.uv.hrtime()

        worst = math.max(worst, (now - last) / 1e6)
        last = now
      end)
      action()
      assert.is_true(vim.wait(60000, function()
        return ws.rendered == ws.generation
      end, 1))
      -- work queued by the render (cursor restore, folds) runs after it is marked done
      vim.wait(200)
      monitor:stop()

      return worst
    end

    path = vim.fn.tempname() .. ".jsonl"
    vim.fn.writefile(gen.jsonl_lines(COUNT), path)
    ws = workspace.open({ path = path })
    assert.is_true(vim.wait(30000, function()
      return not ws.loading and ws.rendered == ws.generation
    end, 50))

    local filter_tick = worst_tick(function()
      ws:add_filter("status>=200")
    end)
    local group_tick = worst_tick(function()
      ws:set_group("path")
    end)
    monitor:close()
    print(string.format("worst tick: filter apply %.0fms, group apply %.0fms (budget 50)", filter_tick, group_tick))
    assert.is_true(filter_tick < 50)
    assert.is_true(group_tick < 50)
  end)

  it("should show appended lines quickly in an ungrouped workspace", function()
    local start, elapsed, extra, before

    path = vim.fn.tempname() .. ".jsonl"
    vim.fn.writefile(gen.jsonl_lines(COUNT), path)
    ws = workspace.open({ path = path })
    assert.is_true(vim.wait(30000, function()
      return not ws.loading and ws.rendered == ws.generation
    end, 50))

    before = vim.api.nvim_buf_line_count(ws.view.bufnr)
    extra = gen.jsonl_lines(100)
    vim.fn.writefile(extra, path, "a")
    -- measured from calling the reload path directly: the fs_event 200ms debounce is excluded
    start = now_ms()
    ws:reload()
    elapsed = now_ms() - start
    print(string.format("append 100 lines -> view: %.1fms (budget 50)", elapsed))
    assert.are.equal(before + #extra, vim.api.nvim_buf_line_count(ws.view.bufnr))
    assert.is_true(elapsed < 50)
  end)
end)
