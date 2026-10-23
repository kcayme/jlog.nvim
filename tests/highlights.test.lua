local highlights = require("jlog.ui.highlights")

describe("highlights", function()
  it("should define every group from the spec as a default link", function()
    highlights.setup()
    assert.are.equal(20, #highlights.GROUPS)
    assert.are.equal("DiagnosticError", vim.api.nvim_get_hl(0, { name = "JLogLevelError" }).link)
    assert.are.equal("Title", vim.api.nvim_get_hl(0, { name = "JLogGroupHeader" }).link)
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
