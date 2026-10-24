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

describe("facets.merge", function()
  local function counted(values)
    local counter = facets_mod.counter()
    for _, value in ipairs(values) do
      facets_mod.add(counter, { id = value })
    end
    return counter
  end

  it("should merge counters exactly when fields stay under the cap", function()
    local first = counted({ 200, 500 })
    local second = counted({ 500 })
    first.fields.status, first.fields.id = first.fields.id, nil
    second.fields.status = second.fields.id
    facets_mod.merge(first, second.fields)
    assert.are.same({ ["200"] = 1, ["500"] = 2 }, first.fields.status.counts)
    assert.are.equal(2, first.fields.status.distinct)
    assert.is_falsy(first.fields.status.estimated)
  end)

  it("should keep at most 1000 values and mark the field estimated when merging past the cap", function()
    local low, high = {}, {}
    for i = 1, 800 do
      low[#low + 1] = i
    end
    for i = 700, 1500 do
      high[#high + 1] = i
    end
    local first, second = counted(low), counted(high)
    facets_mod.merge(first, second.fields)
    assert.are.equal(1000, first.fields.id.distinct)
    assert.is_true(first.fields.id.capped)
    assert.is_true(first.fields.id.estimated)
    assert.is_true(facets_mod.result(first, 10)[1].estimated)
  end)

  it("should append names of fields the counter has not seen", function()
    local first = counted({ 1 })
    facets_mod.merge(first, { other = { counts = { a = 3 }, distinct = 1, capped = false } })
    assert.are.same({ "id", "other" }, first.names)
  end)
end)
