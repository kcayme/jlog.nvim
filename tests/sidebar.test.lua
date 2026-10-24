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
    vim.api.nvim_buf_set_lines(sb, 2, 2, false, { "level=ERROR", 'msg="oops' })
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
    vim.api.nvim_buf_set_lines(sb, 2, 2, false, { 'msg="oops' })
    vim.api.nvim_buf_call(sb, function()
      vim.cmd("write")
    end)
    ws:add_filter("status=200")
    assert.are.same({ "", "FILTERS", "status=200", 'msg="oops' }, vim.api.nvim_buf_get_lines(sb, 0, 4, false))
    assert.are.equal(3, vim.diagnostic.get(sb)[1].lnum)
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
      return ws.rendered == ws.store.generation
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
      return ws.rendered == ws.store.generation
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
      return ws.rendered == ws.store.generation
    end, 10))
    ws.sidebar:expand_field("path")
    local winid = vim.fn.bufwinid(ws.sidebar.bufnr)
    -- field lines stop 2 cells short of the window's right edge
    local width = vim.api.nvim_win_get_width(winid) - vim.fn.getwininfo(winid)[1].textoff - 2
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
      return ws.rendered == ws.store.generation
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
    assert.is_true(longest() <= 58)

    vim.api.nvim_buf_set_lines(ws.sidebar.bufnr, 2, 2, false, { "level=ERROR" })
    vim.api.nvim_win_set_width(winid, 50)
    vim.api.nvim_exec_autocmds("WinResized", {})
    assert.are.equal("level=ERROR", vim.api.nvim_buf_get_lines(ws.sidebar.bufnr, 2, 3, false)[1])
  end)

  it("should keep the cursor on the same field when new fields are rendered above it", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '{"msg":"a","path":"/x"}', '{"msg":"b","path":"/y"}' })
    ws = assert(require("jlog.workspace").open({ bufnr = buf }))
    assert.is_truthy(vim.wait(2000, function()
      return ws.rendered == ws.store.generation
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

  it("should hide the sidebar with the toggle key from inside it", function()
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
    vim.api.nvim_set_current_win(vim.fn.bufwinid(ws.sidebar.bufnr))
    vim.api.nvim_feedkeys("S", "x", false)
    assert.are.equal(-1, vim.fn.bufwinid(ws.sidebar.bufnr))
    assert.are.equal(ws.view.bufnr, vim.api.nvim_get_current_buf())
  end)

  describe("hints", function()
    local function hints(bufnr)
      local found = {}
      local ns = vim.api.nvim_get_namespaces()["jlog.hint"]
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
        found[#found + 1] = { row = mark[2], text = mark[4].virt_text[1][1] }
        -- the right-aligned hint keeps the same right padding as the field lines
        if mark[4].virt_text_pos == "right_align" then
          assert.are.same({ "  " }, mark[4].virt_text[2])
        end
      end

      return found
    end

    it("should show examples on empty FILTERS and GROUP BY lines and how to apply on the first row", function()
      ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
      assert.are.same({
        { row = 0, text = ":w to apply | ? help" },
        { row = 2, text = "status>=500 level=ERROR -health" },
        { row = 4, text = "request_id" },
      }, hints(ws.sidebar.bufnr))
    end)

    it("should hide an example once its section is set", function()
      ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
      ws:add_filter("level=ERROR")
      ws:set_group("request_id")
      assert.are.same({ { row = 0, text = ":w to apply | ? help" } }, hints(ws.sidebar.bufnr))
    end)

    it("should hide examples in insert mode and on a line being typed", function()
      local sb

      ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
      sb = ws.sidebar.bufnr
      vim.api.nvim_buf_call(sb, function()
        vim.api.nvim_exec_autocmds("InsertEnter", { buffer = sb })
      end)
      assert.are.same({ { row = 0, text = ":w to apply | ? help" } }, hints(sb))
      vim.api.nvim_buf_set_lines(sb, 2, 3, false, { "level" })
      vim.api.nvim_buf_call(sb, function()
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = sb })
      end)
      assert.are.same({ { row = 0, text = ":w to apply | ? help" }, { row = 4, text = "request_id" } }, hints(sb))
    end)
  end)

  it("should name the buffers by filetype and leave out the help hint when its key is off", function()
    require("jlog.config").setup({ keymaps = { help = false } })
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
    require("jlog.config").setup()
    assert.are.equal("jlog", vim.bo[ws.view.bufnr].filetype)
    assert.are.equal("jlog_sidebar", vim.bo[ws.sidebar.bufnr].filetype)
    assert.are.same(
      { ":w to apply" },
      vim.tbl_map(
        function(mark)
          return mark[4].virt_text[1][1]
        end,
        vim.api.nvim_buf_get_extmarks(ws.sidebar.bufnr, vim.api.nvim_get_namespaces()["jlog.hint"], 0, 0, {
          details = true,
        })
      )
    )
  end)

  it("should open a guide to the configured keys from the sidebar and close it with q", function()
    local float, lines

    require("jlog.config").setup({ keymaps = { toggle_mode = "X", prev_entry = false } })
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
    vim.api.nvim_set_current_win(vim.fn.bufwinid(ws.sidebar.bufnr))
    assert.are.equal("", vim.wo.winbar)
    vim.api.nvim_feedkeys("?", "x", false)
    float = vim.api.nvim_get_current_win()
    assert.are_not.equal("", vim.api.nvim_win_get_config(float).relative)
    lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    assert.is_truthy(lines:find("X%s+compact/expanded"))
    assert.is_truthy(lines:find("%]%]%s+next/previous entry"))
    assert.is_nil(lines:find("[[", 1, true))
    assert.is_truthy(lines:find(":w%s+apply"))
    vim.api.nvim_feedkeys("q", "x", false)
    assert.is_false(vim.api.nvim_win_is_valid(float))
    require("jlog.config").setup()
  end)

  it(
    "should color field names like their keys in the log view, or use one color when sidebar colors are off",
    function()
      local highlights = require("jlog.ui.highlights")
      local function name_groups()
        local groups = {}
        local ns = vim.api.nvim_get_namespaces()["jlog.sidebar"]
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ws.sidebar.bufnr, ns, 0, -1, { details = true })) do
          if mark[3] == 4 then
            groups[vim.trim(vim.api.nvim_buf_get_lines(ws.sidebar.bufnr, mark[2], mark[2] + 1, false)[1]:sub(5, 18))] =
              mark[4].hl_group
          end
        end

        return groups
      end

      ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
      assert.is_true(vim.wait(2000, function()
        return name_groups().request_id ~= nil
      end))
      assert.are.equal(highlights.field_group("request_id"), name_groups().request_id)
      ws:close()

      require("jlog.config").setup({ sidebar = { field_colors = false } })
      ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
      assert.is_true(vim.wait(2000, function()
        return name_groups().request_id ~= nil
      end))
      assert.are.equal("JLogFieldName", name_groups().request_id)
      require("jlog.config").setup()
    end
  )

  it("should draw a pill field name with inline caps and keep the summaries aligned", function()
    local ns, lines, caps, columns

    require("jlog.config").setup({ sidebar = { fields = { request_id = { style = "pill" } } } })
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
    ns = vim.api.nvim_get_namespaces()["jlog.sidebar"]
    assert.is_true(vim.wait(2000, function()
      lines = vim.api.nvim_buf_get_lines(ws.sidebar.bufnr, 0, -1, false)
      return vim.iter(lines):any(function(line)
        return line:find("request_id", 1, true) ~= nil
      end)
    end))
    caps, columns = {}, {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(ws.sidebar.bufnr, ns, 0, -1, { details = true })) do
      if mark[4].virt_text_pos == "inline" then
        caps[#caps + 1] = mark[4].virt_text[1][1]
      end
    end
    -- the name column ends where the summary starts: same display column on every row, counting the caps
    for row, line in ipairs(lines) do
      local name = ws.sidebar.rows[row] and ws.sidebar.rows[row].value == nil and ws.sidebar.rows[row].name
      if name then
        local start = line:find("  %S", 4 + #name)
        local extra = name == "request_id" and vim.fn.strdisplaywidth(table.concat(caps)) or 0
        columns[#columns + 1] = vim.fn.strdisplaywidth(line:sub(1, start)) + extra
      end
    end

    assert.are.same({ "\u{e0b6}", "\u{e0b4}" }, caps)
    assert.is_true(#columns > 1)
    assert.are.same(vim.fn.uniq(vim.fn.sort(vim.deepcopy(columns))), { columns[1] })
    require("jlog.config").setup()
  end)

  it("should mark the counts of an estimated field with ~", function()
    local lines
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/loki.json", ":p") })
    ws.sidebar.facets = {
      { name = "request_id", distinct = 1000, capped = true, estimated = true, top = { { value = "r0", count = 20 } } },
    }
    ws.sidebar:expand_field("request_id")
    lines = table.concat(vim.api.nvim_buf_get_lines(ws.sidebar.bufnr, 0, -1, false), "\n")
    assert.is_truthy(lines:find("1000+ values", 1, true))
    assert.is_truthy(lines:find("r0 (~20)", 1, true))
  end)

  it("should show exact counts without ~", function()
    local lines
    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/loki.json", ":p") })
    ws.sidebar.facets = {
      {
        name = "request_id",
        distinct = 1000,
        capped = true,
        estimated = false,
        top = { { value = "r0", count = 20 } },
      },
    }
    ws.sidebar:expand_field("request_id")
    lines = table.concat(vim.api.nvim_buf_get_lines(ws.sidebar.bufnr, 0, -1, false), "\n")
    assert.is_truthy(lines:find("r0 (20)", 1, true))
    assert.is_falsy(lines:find("~", 1, true))
  end)
end)
