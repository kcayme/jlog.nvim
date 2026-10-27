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

  it("should count the entries a field appears in past the distinct cap", function()
    local idxs = {}
    for i = 1, 1500 do
      idxs[i] = i
    end
    local facets = facets_mod.count(idxs, function(i)
      return i % 2 == 0 and { id = i, even = true } or { id = i }
    end, 1)
    local present = {}
    for _, facet in ipairs(facets) do
      present[facet.name] = facet.present
    end

    assert.are.same({ id = 1500, even = 750 }, present)
  end)

  it("should add up the entries a field appears in when merging counters", function()
    local counter, other = facets_mod.counter(), facets_mod.counter()
    for i = 1, 3 do
      facets_mod.add(counter, { a = i })
    end
    for i = 1, 1200 do
      facets_mod.add(other, { a = i })
    end
    facets_mod.merge(counter, other.fields)

    assert.are.equal(1203, facets_mod.result(counter, 1)[1].present)
  end)

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
    facets_mod.merge(first, { other = { counts = { a = 3 }, distinct = 1, capped = false, present = 3 } })
    assert.are.same({ "id", "other" }, first.names)
  end)
end)

describe("facets.add_value", function()
  it("should count a value like add, skipping nil and tables", function()
    local counter = facets_mod.counter()

    facets_mod.add_value(counter, "status", 500)
    facets_mod.add_value(counter, "status", "500")
    facets_mod.add_value(counter, "status", nil)
    facets_mod.add_value(counter, "status", { 1 })

    assert.are.same({ "status" }, counter.names)
    assert.are.same({ ["500"] = 2 }, counter.fields.status.counts)
    assert.are.equal(2, counter.fields.status.present)
  end)
end)

describe("facets.override", function()
  it("should replace the fields it has", function()
    local counter, other = facets_mod.counter(), facets_mod.counter()

    facets_mod.add(counter, { status = 500, id = 1 })
    facets_mod.add(other, { status = 200 })
    facets_mod.add(other, { level = "INFO" })
    facets_mod.override(counter, other)

    assert.are.same({ ["200"] = 1 }, counter.fields.status.counts)
    assert.are.same({ ["1"] = 1 }, counter.fields.id.counts)
    table.sort(counter.names)
    assert.are.same({ "id", "status" }, counter.names)
  end)

  it("should add a missing name unless it is aliased", function()
    local counter, other = facets_mod.counter(), facets_mod.counter()

    facets_mod.add(other, { level = "ERROR", path = "/x" })
    facets_mod.override(counter, other)

    assert.are.same({ "path" }, counter.names)
  end)
end)

describe("facets.count_entry", function()
  local entry_model = require("jlog.parse.entry")
  local source = require("jlog.parse.source")

  ---Count the entries of `text` and return each field's value counts.
  local function counts_of(text, labels)
    local counter = facets_mod.counter()
    local result = {}

    for _, entry in ipairs(source.build(text, "jsonl")) do
      entry.labels = labels
      facets_mod.count_entry(counter, entry, entry_model.decode(entry))
    end
    for name, field in pairs(counter.fields) do
      result[name] = field.counts
    end

    return result
  end

  it("should count nested values by dotted name and skip arrays and nulls", function()
    assert.are.same({
      ["req.method"] = { GET = 1 },
      ["req.h.host"] = { x = 1 },
      n = { ["1"] = 1 },
    }, counts_of('{"req":{"method":"GET","h":{"host":"x"}},"n":1,"tags":["a"],"gone":null}'))
  end)

  it("should count a field that first appears in a later entry", function()
    assert.are.same(
      { level = { INFO = 2 }, ["http.status"] = { ["500"] = 1 } },
      counts_of('{"level":"INFO"}\n{"level":"INFO","http":{"status":500}}')
    )
  end)

  it("should count labels under labels. with their dotted keys", function()
    assert.are.same(
      { a = { ["1"] = 1 }, ["labels.app.kubernetes.io/name"] = { api = 1 } },
      counts_of('{"a":1}', { ["app.kubernetes.io/name"] = "api" })
    )
  end)

  it("should count integers too big for a double as written, and the rest of the entry once", function()
    assert.are.same(
      { id = { ["12345678901234567890"] = 1 }, n = { ["1"] = 1 } },
      counts_of('{"id":12345678901234567890,"n":1}')
    )
  end)
end)
