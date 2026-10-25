local config = require("jlog.config")

describe("config", function()
  it("should return defaults when setup has no options", function()
    local opts = config.setup()
    assert.are.same({ "time", "ts", "timestamp", "@timestamp", "time_stamp", "timeStamp" }, opts.fields.time)
    assert.are.equal("compact", opts.view.mode)
    assert.are.equal(4, opts.unwrap.max_depth)
    assert.are.equal("<CR>", opts.keymaps.toggle_entry)
    assert.are.same({}, opts.view.ignore_fields)
    assert.are.equal("s", opts.keymaps.ignore_field)
  end)

  it("should deep-merge user options", function()
    local opts = config.setup({ sidebar = { width = 60 }, keymaps = { close = false } })
    assert.are.equal(60, opts.sidebar.width)
    assert.are.equal("right", opts.sidebar.position)
    assert.is_false(opts.keymaps.close)
    assert.are.equal(opts, config.options)
  end)

  describe("sidebar.sections", function()
    local real_notify = vim.notify
    local warnings

    before_each(function()
      warnings = {}
      vim.notify = function(msg, level)
        if level == vim.log.levels.WARN then
          warnings[#warnings + 1] = msg
        end
      end
    end)

    after_each(function()
      vim.notify = real_notify
      config.setup()
    end)

    it("should warn when setup is given unknown or repeated sections and drop them", function()
      local opts = config.setup({ sidebar = { sections = { "fields", "bogus", "sort", "fields" } } })

      assert.are.same({ "fields", "sort" }, opts.sidebar.sections)
      assert.are.equal(2, #warnings)
      assert.is_truthy(warnings[1]:find('sidebar.sections: unknown section "bogus"', 1, true))
      assert.is_truthy(warnings[2]:find('sidebar.sections: "fields" is listed twice', 1, true))
    end)

    it("should warn and fall back to the default order when sections is not a list of names", function()
      local opts = config.setup({ sidebar = { sections = "fields" } })

      assert.are.same({ "filters", "group", "limit", "sort", "fields" }, opts.sidebar.sections)
      assert.are.equal(1, #warnings)
      assert.is_truthy(warnings[1]:find("sidebar.sections", 1, true))
    end)

    it("should not warn about the default or a valid list", function()
      config.setup()
      config.setup({ sidebar = { sections = { "fields" } } })

      assert.are.same({}, warnings)
    end)
  end)
end)
