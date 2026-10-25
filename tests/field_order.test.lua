local config = require("jlog.config")
local field_order = require("jlog.ui.field_order")

---Facets as `facets.result` gives them: alphabetical, labels last.
local function facets(list)
  return vim.tbl_map(function(item)
    return { name = item[1], present = item[2], label = item[1]:sub(1, 7) == "labels." }
  end, list)
end

local function names(list)
  return vim.tbl_map(function(facet)
    return facet.name
  end, list)
end

describe("field_order", function()
  local counted = facets({ { "a", 1 }, { "b", 9 }, { "lvl", 3 }, { "status", 5 }, { "labels.app", 20 } })

  after_each(function()
    config.setup()
  end)

  it("should keep the alphabetical order, labels last, by default", function()
    local opts = config.setup()

    assert.are.same({ "a", "b", "lvl", "status", "labels.app" }, names(field_order.order(counted, opts, {}, true)))
  end)

  it("should put pinned fields first in their order, by name or role, skipping missing ones", function()
    local opts = config.setup({
      fields = { level = { "lvl" } },
      sidebar = { fields = { pinned = { "status", "missing", "level" } } },
    })

    assert.are.same({ "status", "lvl", "a", "b", "labels.app" }, names(field_order.order(counted, opts, {}, true)))
  end)

  it("should sort the rest by entries, ties by name, labels last, once the counts are final", function()
    local opts = config.setup({ sidebar = { fields = { pinned = { "a" }, sort = "count" } } })
    local tied = facets({ { "a", 1 }, { "c", 5 }, { "b", 5 }, { "d", 9 }, { "labels.app", 20 } })

    assert.are.same({ "a", "d", "b", "c", "labels.app" }, names(field_order.order(tied, opts, {}, true)))
  end)

  it("should keep the previous order while counts are partial and add new fields at the end", function()
    local opts = config.setup({ sidebar = { fields = { sort = "count" } } })
    local previous = facets({ { "status", 5 }, { "a", 1 } })
    local partial = facets({ { "a", 50 }, { "new", 99 }, { "status", 6 } })

    assert.are.same({ "status", "a", "new" }, names(field_order.order(partial, opts, previous, false)))
  end)
end)
