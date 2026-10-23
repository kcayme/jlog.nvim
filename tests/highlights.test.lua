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

  it("should define every group from the spec as a default link", function()
    highlights.setup()
    assert.are.equal(22, #highlights.GROUPS)
    assert.are.equal("Comment", vim.api.nvim_get_hl(0, { name = "JLogOverlap" }).link)
    assert.are.equal("Title", vim.api.nvim_get_hl(0, { name = "JLogGroupHeader" }).link)
    assert.are.equal("NonText", vim.api.nvim_get_hl(0, { name = "JLogFieldStale" }).link)
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
