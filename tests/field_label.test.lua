local config = require("jlog.config")
local field_label = require("jlog.ui.field_label")
local highlights = require("jlog.ui.highlights")

describe("field_label", function()
  local real_notify = vim.notify

  after_each(function()
    vim.notify = real_notify
    config.setup()
  end)

  it("should show the name plain in its field color by default", function()
    local opts = config.setup()

    assert.are.same({ "status", highlights.field_group("status") }, { field_label.of(opts, "status", 3) })
  end)

  it("should use JLogFieldName for every name when sidebar field colors are off", function()
    local opts = config.setup({ sidebar = { field_colors = false } })

    assert.are.same({ "status", "JLogFieldName" }, { field_label.of(opts, "status", 3) })
  end)

  it("should draw every name as a badge of its color when the sidebar style is inverted", function()
    local opts = config.setup({ sidebar = { style = "inverted" } })
    local color = highlights.field_group("msg")

    assert.are.same({ "msg", highlights.badge_of(color) }, { field_label.of(opts, "msg", 3) })
  end)

  it("should style a field by its name before its role, and give a pill its cap group", function()
    local opts = config.setup({
      sidebar = { fields = { level = { style = "inverted" }, lvl = { style = "pill" } } },
      fields = { level = { "lvl" } },
    })
    local color = highlights.field_group("lvl")

    assert.are.same({ "lvl", highlights.badge_of(color), color }, { field_label.of(opts, "lvl", 3) })
  end)

  it("should style a field by its role when the name has no entry", function()
    local opts = config.setup({ sidebar = { fields = { level = { style = "inverted" } } } })
    local color = highlights.field_group("severity")

    assert.are.same({ "severity", highlights.badge_of(color) }, { field_label.of(opts, "severity", 3) })
  end)

  it("should pass the name and distinct count to format and use its text and group", function()
    local seen
    local opts = config.setup({
      sidebar = {
        fields = {
          ["req.method"] = {
            format = function(ctx)
              seen = { ctx.name, ctx.distinct }

              return ctx.name:upper(), "Special"
            end,
          },
        },
      },
    })

    assert.are.same({ "REQ.METHOD", "Special" }, { field_label.of(opts, "req.method", 5) })
    assert.are.same({ "req.method", 5 }, seen)
  end)

  it("should fall back to the name and warn once when format fails", function()
    local warnings = {}
    local opts = config.setup({
      sidebar = {
        fields = {
          msg = {
            format = function()
              error("boom")
            end,
          },
        },
      },
    })

    vim.notify = function(msg)
      warnings[#warnings + 1] = msg
    end
    field_label.of(opts, "msg", 1)

    assert.are.same({ "msg", highlights.field_group("msg") }, { field_label.of(opts, "msg", 1) })
    assert.are.equal(1, #warnings)
    assert.is_truthy(warnings[1]:find("format for msg failed", 1, true))
  end)
end)
