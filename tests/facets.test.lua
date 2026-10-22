local facets_mod = require("jlog.query.facets")

describe("facets.count", function()
  it("should count values, sort names and put labels last", function()
    local flats = { { status = 200, ["labels.pod"] = "p" }, { status = 200 }, { status = 500 } }
    local facets = facets_mod.count({ 1, 2, 3 }, function(i)
      return flats[i]
    end, 10)
    assert.are.equal("status", facets[1].name)
    assert.are.same({ value = "200", count = 2 }, facets[1].top[1])
    assert.are.equal("labels.pod", facets[2].name)
  end)

  it("should cap distinct values but keep counting existing ones", function()
    local idxs = {}
    for i = 1, 1002 do
      idxs[i] = i
    end
    idxs[1003] = 1
    local facets = facets_mod.count(idxs, function(i)
      return { id = i }
    end, 1)
    assert.is_true(facets[1].capped)
    assert.are.equal(1000, facets[1].distinct)
    assert.are.equal(1, #facets[1].top)
  end)
end)
