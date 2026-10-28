describe("keymaps", function()
  local ws

  after_each(function()
    if ws then
      ws:close()
    end
  end)

  it("should list the filter syntax in the key guide, aligned to its longest syntax", function()
    local lines

    ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
    vim.api.nvim_set_current_win(vim.fn.bufwinid(ws.sidebar.bufnr))
    vim.fn.maparg("?", "n", false, true).callback()
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    vim.api.nvim_win_close(0, true)

    assert.is_true(vim.tbl_contains(lines, "Filter syntax"))
    assert.is_true(vim.tbl_contains(lines, "  field=value equal; != not equal"))
    assert.is_true(vim.tbl_contains(lines, "  value       Vim regex on the whole entry"))
    assert.is_true(vim.tbl_contains(lines, "  q        close"))
  end)
end)
