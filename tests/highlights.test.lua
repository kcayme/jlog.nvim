local highlights = require("jlog.ui.highlights")

describe("highlights", function()
  it("should be defined by the plugin file when setup is never called", function()
    local result = vim
      .system({
        "nvim",
        "--headless",
        "--clean",
        "--cmd",
        "set rtp^=.",
        "-c",
        "lua io.stdout:write(tostring(next(vim.api.nvim_get_hl(0, { name = 'JLogTime' })) ~= nil))",
        "-c",
        "qa!",
      }, { text = true })
      :wait(10000)

    assert.are.equal("true", vim.trim(result.stdout))
  end)

  it("should define every highlight group as a default link", function()
    highlights.setup()
    assert.are.equal(27, #highlights.GROUPS)
    assert.are.equal("Comment", vim.api.nvim_get_hl(0, { name = "JLogOverlap" }).link)
    assert.are.equal("Title", vim.api.nvim_get_hl(0, { name = "JLogGroupHeader" }).link)
    assert.are.equal("NonText", vim.api.nvim_get_hl(0, { name = "JLogFieldStale" }).link)
    assert.are.equal("Comment", vim.api.nvim_get_hl(0, { name = "JLogHint" }).link)
    assert.are.equal("Identifier", vim.api.nvim_get_hl(0, { name = "JLogField1" }).link)
  end)

  it("should never give a field key the color of a value", function()
    local value_colors = {}

    vim.cmd("hi clear")
    vim.api.nvim_set_hl(0, "String", { fg = "#00aa00" })
    vim.api.nvim_set_hl(0, "Number", { fg = "#aa0000" })
    vim.api.nvim_set_hl(0, "Identifier", { fg = "#00aa00" })
    vim.api.nvim_set_hl(0, "Constant", { fg = "#aa0000" })
    vim.api.nvim_set_hl(0, "Function", { fg = "#0000aa" })
    highlights.setup()
    for _, name in ipairs({ "JLogValue", "JLogString", "JLogNumber", "JLogBoolean", "JLogNull" }) do
      value_colors[vim.api.nvim_get_hl(0, { name = name, link = false }).fg or false] = true
    end
    for index = 1, highlights.FIELD_COLORS do
      assert.is_nil(value_colors[vim.api.nvim_get_hl(0, { name = "JLogField" .. index, link = false }).fg])
    end
    assert.are.equal("Function", vim.api.nvim_get_hl(0, { name = "JLogField1" }).link)
    vim.cmd("hi clear")
    highlights.setup()
  end)

  it("should draw pill caps in the fg of a foreground-only level override", function()
    vim.cmd("hi clear")
    highlights.setup()
    vim.api.nvim_set_hl(0, "JLogLevelError", { fg = "#ff0000" })
    assert.are.equal(0xff0000, vim.api.nvim_get_hl(0, { name = highlights.cap_of("JLogLevelError"), link = false }).fg)
    vim.cmd("hi clear")
    highlights.setup()
  end)

  it("should give fields colors in first-seen order and cycle after the last", function()
    local seen = {}
    local first = highlights.field_group("cycle_0")

    seen[first] = true
    for index = 1, highlights.FIELD_COLORS - 1 do
      seen[highlights.field_group("cycle_" .. index)] = true
    end
    assert.are.equal(highlights.FIELD_COLORS, vim.tbl_count(seen))
    assert.are.equal(first, highlights.field_group("cycle_" .. highlights.FIELD_COLORS))
    assert.are.equal(first, highlights.field_group("cycle_0"))
  end)

  it("should draw levels as badges in the level's color", function()
    vim.cmd("hi clear")
    vim.api.nvim_set_hl(0, "DiagnosticError", { fg = "#ff0000", ctermfg = 1 })
    highlights.setup()
    local level = vim.api.nvim_get_hl(0, { name = "JLogLevelError" })
    assert.are.equal(0xff0000, level.fg)
    assert.are.equal(1, level.ctermfg)
    assert.is_true(level.reverse)
    assert.is_true(level.bold)
  end)

  it("should link status classes to diagnostics", function()
    highlights.setup()
    assert.are.equal("DiagnosticError", vim.api.nvim_get_hl(0, { name = "JLogStatus5xx" }).link)
    assert.are.equal("DiagnosticOk", vim.api.nvim_get_hl(0, { name = "JLogStatus2xx" }).link)
  end)

  it("should build a reversed badge from a color group and rebuild it after a colorscheme change", function()
    local badge

    vim.cmd("hi clear")
    vim.api.nvim_set_hl(0, "Function", { fg = "#0000aa" })
    highlights.setup()
    badge = vim.api.nvim_get_hl(0, { name = highlights.badge_of("Function"), link = false })
    assert.are.equal(0x0000aa, badge.fg)
    assert.is_true(badge.reverse)
    assert.is_true(badge.bold)

    vim.cmd("hi clear")
    vim.api.nvim_set_hl(0, "Function", { fg = "#00aa00" })
    highlights.setup()
    badge = vim.api.nvim_get_hl(0, { name = highlights.badge_of("Function"), link = false })
    assert.are.equal(0x00aa00, badge.fg)
    vim.cmd("hi clear")
    highlights.setup()
  end)

  it("should return the default link of a group", function()
    assert.are.equal("DiagnosticWarn", highlights.link_of("JLogLevelWarn"))
    assert.is_nil(highlights.link_of("JLogNope"))
  end)

  it("should leave user overrides alone", function()
    vim.api.nvim_set_hl(0, "JLogKey", { fg = "#00ff00" })
    highlights.setup()
    assert.are.equal(0x00ff00, vim.api.nvim_get_hl(0, { name = "JLogKey" }).fg)
  end)

  it("should cover every group name render.lua uses", function()
    local names = {}
    for _, row in ipairs(highlights.GROUPS) do
      names[row.name] = true
    end
    local source = table.concat(vim.fn.readfile("lua/jlog/ui/render.lua"), "\n")
    for name in source:gmatch('"(JLog%w+)"') do
      assert.is_true(names[name], name .. " is used by render.lua but not defined")
    end
  end)
end)
