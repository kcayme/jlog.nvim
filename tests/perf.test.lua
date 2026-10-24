local gen = dofile("bench/gen.lua")
local source = require("jlog.parse.source")
local filter = require("jlog.query.filter")
local group = require("jlog.query.group")
local render = require("jlog.ui.render")
local entry_model = require("jlog.parse.entry")
local workspace = require("jlog.workspace")

-- throughput budgets scale per line from the 100k figures; latency budgets are the same at every size
local SIZES = { 10000, 100000, 500000 }
local US_PER_LINE = { build = 10, compact = 15, filter_group = 10 }

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

---Run `action`, wait until `is_done`, and return the longest gap between main-loop ticks meanwhile.
---@param action fun()
---@param is_done fun(): boolean
---@return number worst_ms
local function worst_tick(action, is_done)
  local monitor = vim.uv.new_timer()
  local worst, last = 0, vim.uv.hrtime()

  monitor:start(0, 1, function()
    local now = vim.uv.hrtime()

    worst = math.max(worst, (now - last) / 1e6)
    last = now
  end)
  action()
  assert.is_true(vim.wait(60000, is_done, 1))
  -- work queued once it is done (cursor restore, folds, counting) runs after it
  vim.wait(200)
  monitor:stop()
  monitor:close()

  return worst
end

---Write a generated log to a temp file; the generator's garbage is collected so the plugin is not timed paying it.
---@param lines string[]
---@param extension string
---@return string path
local function write_log(lines, extension)
  local path = vim.fn.tempname() .. extension

  vim.fn.writefile(lines, path)
  collectgarbage("collect")

  return path
end

---@param ws JLogWorkspace
---@return fun(): boolean
local function settled(ws)
  return function()
    return not ws.loading and ws.rendered == ws.store.generation
  end
end

---@param ws JLogWorkspace
---@param action fun()
---@return number elapsed_ms
local function time_apply(ws, action)
  local start = now_ms()

  action()
  assert.is_true(vim.wait(60000, settled(ws), 1))

  return now_ms() - start
end

if vim.env.JLOG_PERF ~= "1" then
  return
end

for _, count in ipairs(SIZES) do
  describe(string.format("perf (%dk lines)", count / 1000), function()
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
      text = table.concat(gen.jsonl_lines(count), "\n") .. "\n"
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
      -- each check starts from a heap like a fresh session's, not one holding the last check's 500k entries
      entries = nil
      collectgarbage("collect")
    end)

    it("should parse, render, filter and stay within memory budgets", function()
      local start, elapsed, budget, pred, entry, decoded, matched, items, ctx, ordered_opts, unconfigured
      local function key_format(format_ctx)
        return format_ctx.key .. " " .. format_ctx.value
      end

      ordered_opts = vim.tbl_deep_extend("force", vim.deepcopy(opts), {
        compact = {
          order = { "status", "path", "request_id" },
          fields = {
            status = { format = key_format },
            path = { format = key_format },
            method = { format = key_format },
          },
        },
      })
      start = now_ms()
      entries = source.build(text, "jsonl")
      elapsed = now_ms() - start
      budget = count * US_PER_LINE.build / 1000
      print(string.format("source.build: %.0fms (budget %.0f)", elapsed, budget))
      assert.is_true(elapsed < budget)

      start = now_ms()
      for _, item in ipairs(entries) do
        render.compact(item, opts, true)
      end
      elapsed = now_ms() - start
      budget = count * US_PER_LINE.compact / 1000
      print(string.format("render.compact x%d: %.0fms (budget %.0f)", #entries, elapsed, budget))
      assert.is_true(elapsed < budget)
      unconfigured = elapsed

      start = now_ms()
      for _, item in ipairs(entries) do
        render.compact(item, ordered_opts, true)
      end
      elapsed = now_ms() - start
      -- printed, not asserted: it runs second in one process, which inflates it; +5% is measured one process per config
      print(
        string.format(
          "render.compact with order + 3 formats x%d: %.0fms (budget %.0f, %.2fx unconfigured)",
          #entries,
          elapsed,
          budget,
          elapsed / unconfigured
        )
      )
      assert.is_true(elapsed < budget)

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
      -- filter/group apply gets 1000ms per 100k; 300ms had too little headroom to be stable
      budget = count * US_PER_LINE.filter_group / 1000
      print(string.format("filter.compile + group.build (%d shown): %.0fms (budget %.0f)", #items, elapsed, budget))
      assert.is_true(elapsed < budget)
    end)

    it("should show the first screen before the whole log is parsed", function()
      local start, elapsed

      path = write_log(gen.jsonl_lines(count), ".jsonl")
      start = now_ms()
      ws = workspace.open({ path = path })
      elapsed = now_ms() - start
      print(string.format("workspace.open -> first lines in view: %.0fms (budget 300)", elapsed))
      assert.is_true(#vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false) > 0)
      assert.is_true(ws.loading)
      assert.is_true(elapsed < 300)
    end)

    it("should keep every main-loop tick short while a filter or group applies", function()
      local filter_tick, group_tick

      path = write_log(gen.jsonl_lines(count), ".jsonl")
      ws = workspace.open({ path = path })
      assert.is_true(vim.wait(30000, settled(ws), 50))

      filter_tick = worst_tick(function()
        ws:add_filter("status>=200")
      end, settled(ws))
      group_tick = worst_tick(function()
        ws:set_group("path")
      end, settled(ws))
      print(string.format("worst tick: filter apply %.0fms, group apply %.0fms (budget 100)", filter_tick, group_tick))
      assert.is_true(filter_tick < 100)
      assert.is_true(group_tick < 100)
    end)

    it("should search a 100k page in under a second", function()
      local elapsed

      path = write_log(gen.jsonl_lines(count), ".jsonl")
      ws = workspace.open({ path = path })
      assert.is_true(vim.wait(30000, settled(ws), 50))

      elapsed = time_apply(ws, function()
        ws:add_filter("licence")
      end)
      print(string.format("search licence (%d shown of %d): %.0fms (budget 1000)", ws.shown, #ws.entries, elapsed))
      assert.is_true(elapsed < 1000)
    end)

    it("should group a 100k page by request_id in under two seconds", function()
      local elapsed

      path = write_log(gen.jsonl_lines(count), ".jsonl")
      ws = workspace.open({ path = path })
      assert.is_true(vim.wait(30000, settled(ws), 50))

      elapsed = time_apply(ws, function()
        ws:set_group("request_id")
      end)
      print(string.format("group request_id (%d entries): %.0fms (budget 2000)", #ws.entries, elapsed))
      assert.is_true(elapsed < 2000)
    end)

    it("should show a grafana export's first screen quickly", function()
      local start, elapsed

      path = write_log({ gen.loki_text(count, true) }, ".json")
      start = now_ms()
      ws = workspace.open({ path = path })
      elapsed = now_ms() - start
      print(string.format("grafana export open -> first lines in view: %.0fms (budget 300)", elapsed))
      assert.is_true(#vim.api.nvim_buf_get_lines(ws.view.bufnr, 0, -1, false) > 1)
      assert.is_true(elapsed < 300)
    end)

    it("should keep every tick short while a grafana export loads", function()
      local tick

      path = write_log({ gen.loki_text(count, true) }, ".json")
      -- open itself is the first screen, checked above; the ticks after it must stay short
      ws = workspace.open({ path = path })
      tick = worst_tick(function() end, function()
        return settled(ws)() and ws.indexing == nil
      end)
      print(string.format("worst tick: grafana export load %.0fms (budget 100)", tick))
      assert.is_true(tick < 100)
    end)

    it("should group a grafana export's 100k page by request_id in under two seconds", function()
      local elapsed

      -- its plain lines have no request_id, so the page has a missing-value group
      path = write_log({ gen.loki_text(count, true) }, ".json")
      ws = workspace.open({ path = path })
      assert.is_true(vim.wait(60000, function()
        return settled(ws)() and ws.indexing == nil
      end, 50))

      elapsed = time_apply(ws, function()
        ws:set_group("request_id")
      end)
      print(string.format("grafana group request_id (%d entries): %.0fms (budget 2000)", #ws.entries, elapsed))
      assert.is_true(elapsed < 2000)
    end)

    it("should show appended lines quickly in an ungrouped workspace", function()
      local start, elapsed, extra, before

      path = write_log(gen.jsonl_lines(count), ".jsonl")
      ws = workspace.open({ path = path })
      assert.is_true(vim.wait(30000, function()
        return not ws.loading and ws.rendered == ws.store.generation
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

    -- the viewport targets are measured on a nested 100k page only
    if count == 100000 then
      local function complete(ws_arg)
        return function()
          return ws_arg.view ~= nil and ws_arg.view.complete == true
        end
      end

      it("should show a nested page's first compact screen within 300ms", function()
        local start, elapsed, view, first, last, item_index, entry, expected, offset

        path = write_log(gen.nested_lines(count), ".jsonl")
        start = now_ms()
        ws = workspace.open({ path = path })
        elapsed = now_ms() - start
        view = ws.view
        print(string.format("nested open -> first compact screen: %.0fms (budget 300)", elapsed))
        assert.is_true(elapsed < 300)

        vim.api.nvim_win_call(vim.fn.win_findbuf(view.bufnr)[1], function()
          first, last = vim.fn.line("w0"), vim.fn.line("w$")
        end)
        for lnum = first, last do
          item_index = view.line_item[lnum]
          entry = ws.entries[view.items[item_index].idx]
          expected = render.compact(entry, opts, true)
          offset = lnum - view.item_line[item_index] + 1
          assert.are.equal(expected[offset], vim.api.nvim_buf_get_lines(view.bufnr, lnum - 1, lnum, false)[1])
        end
      end)

      it("should keep every tick short while a nested page fills", function()
        local tick

        path = write_log(gen.nested_lines(count), ".jsonl")
        -- open itself is the first screen, checked above; the ticks after it must stay short
        ws = workspace.open({ path = path })
        tick = worst_tick(function() end, complete(ws))
        print(string.format("worst tick: nested fill after open %.1fms (budget 16)", tick))
        assert.is_true(tick < 16)
      end)

      it("should show a request_id filter's results within 300ms after open", function()
        local elapsed

        path = write_log(gen.nested_lines(count), ".jsonl")
        ws = workspace.open({ path = path })
        -- the page index scans in background ticks; filtering meanwhile would time that work too
        assert.is_true(vim.wait(60000, function()
          return complete(ws)() and settled(ws)() and ws.indexing == nil
        end, 50))

        elapsed = time_apply(ws, function()
          ws:add_filter("request_id=req-00020000")
        end)
        print(string.format("nested filter request_id (%d shown): %.0fms (budget 300)", ws.shown, elapsed))
        assert.are.equal(3, ws.shown)
        assert.is_true(elapsed < 300)
      end)

      it("should keep the Lua heap within 3x the file while a nested page fills", function()
        local before, peak, monitor, bytes

        path = write_log(gen.nested_lines(count), ".jsonl")
        bytes = vim.uv.fs_stat(path).size
        before = collectgarbage("count")
        peak = before
        monitor = vim.uv.new_timer()
        monitor:start(0, 1, function()
          peak = math.max(peak, collectgarbage("count"))
        end)
        ws = workspace.open({ path = path })
        assert.is_true(vim.wait(60000, complete(ws), 1))
        monitor:stop()
        monitor:close()
        print(string.format("nested heap growth: %.1f MB for %.1f MB file", (peak - before) / 1024, bytes / 1048576))
        assert.is_true(peak - before < 3 * bytes / 1024)
      end)
    end

    -- page changes only exist past one page
    if count <= 100000 then
      return
    end

    it("should keep every tick short while changing pages", function()
      local step_tick, switch_tick

      path = write_log(gen.jsonl_lines(count), ".jsonl")
      ws = workspace.open({ path = path })
      assert.is_true(vim.wait(30000, function()
        return settled(ws)() and ws.indexing == nil
      end, 50))

      step_tick = worst_tick(function()
        ws:goto_page(2)
      end, function()
        return settled(ws)() and ws.page == 2
      end)
      -- a page asked for while another still loads drops the partial one
      switch_tick = worst_tick(function()
        ws:goto_page(3)
        vim.wait(300)
        ws:goto_page(4)
      end, function()
        return settled(ws)() and ws.page == 4
      end)
      print(
        string.format(
          "worst tick: page change %.0fms, page switch mid-load %.0fms (budget 100)",
          step_tick,
          switch_tick
        )
      )
      assert.is_true(step_tick < 100)
      assert.is_true(switch_tick < 100)
    end)

    it("should keep every tick short while appended lines are shown and the pages indexed again", function()
      local tick

      path = write_log(gen.jsonl_lines(count), ".jsonl")
      ws = workspace.open({ path = path })
      assert.is_true(vim.wait(30000, function()
        return settled(ws)() and ws.indexing == nil
      end, 50))

      vim.fn.writefile(gen.jsonl_lines(100), path, "a")
      tick = worst_tick(function()
        ws:reload()
      end, function()
        return settled(ws)() and ws.appended == nil and ws.indexing == nil
      end)
      print(string.format("worst tick: append on page 1 + re-index %.0fms (budget 100)", tick))
      assert.is_true(tick < 100)
    end)
  end)
end
