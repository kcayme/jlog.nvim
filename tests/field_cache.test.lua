local field_cache = require("jlog.query.field_cache")

describe("field_cache", function()
  local cache, entries, reads

  ---A reader that counts its calls and answers from `values`.
  local function reader(values)
    return function(path)
      reads = reads + 1

      return values[path]
    end
  end

  before_each(function()
    cache, reads = field_cache.new(), 0
    entries = { { raw = "a" }, { raw = "b" } }
    field_cache.use(cache, entries)
  end)

  it("should read a field once per entry, a missing one too", function()
    local read = reader({ status = 500 })

    for _ = 1, 3 do
      assert.are.equal(500, field_cache.get(cache, 1, entries[1], "status", read))
      assert.is_nil(field_cache.get(cache, 1, entries[1], "path", read))
    end
    assert.are.equal(2, reads)
  end)

  it("should read again when another entry is at the index", function()
    field_cache.get(cache, 1, entries[1], "status", reader({ status = 500 }))
    entries[1] = { raw = "c" }

    assert.are.equal(200, field_cache.get(cache, 1, entries[1], "status", reader({ status = 200 })))
    assert.are.equal(2, reads)
  end)

  it("should drop every value for another list of entries", function()
    local other = { entries[1] }

    field_cache.get(cache, 1, entries[1], "status", reader({ status = 500 }))
    field_cache.use(cache, other)

    assert.are.equal(404, field_cache.get(cache, 1, other[1], "status", reader({ status = 404 })))
    assert.are.equal(2, reads)
  end)

  it("should not keep object values", function()
    local read = reader({ http = { status = 500 } })

    field_cache.get(cache, 1, entries[1], "http", read)
    field_cache.get(cache, 1, entries[1], "http", read)

    assert.are.equal(2, reads)
  end)
end)
