local filter = require("jlog.query.filter")
local function ctx(fields, raw)
  return {
    get = function(path)
      return fields[path]
    end,
    raw = raw or "",
  }
end
local function match(lines, fields, raw)
  local pred = filter.compile(type(lines) == "table" and lines or { lines })

  return pred(ctx(fields, raw))
end

describe("filter", function()
  describe("time ranges", function()
    local early = { time = "2026-10-22T09:59:59.999Z" }
    local inside = { time = "2026-10-22T12:30:00+02:00" }
    local late = { time = "2026-10-22T11:00:00.000Z" }
    local range = "time>=2026-10-22T10:00:00Z time<2026-10-22T11:00:00Z"

    it("should compare ISO times as instants, whatever their offset or fraction", function()
      assert.is_false(match(range, early))
      assert.is_true(match(range, inside))
      assert.is_false(match(range, late))
      assert.is_true(match("time>2026-10-22T09:59:59.998Z", early))
    end)

    it("should take a date-only bound as local midnight", function()
      local midnight = os.time({ year = 2026, month = 10, day = 22, hour = 0, min = 0, sec = 0 })

      assert.is_true(match("time>=2026-10-22", { time = os.date("!%Y-%m-%dT%H:%M:%SZ", midnight) }))
      assert.is_false(match("time>=2026-10-22", { time = os.date("!%Y-%m-%dT%H:%M:%SZ", midnight - 1) }))
    end)

    it("should work on any field and never match a value that is not a time", function()
      assert.is_true(match("created_at<2026-10-23", { created_at = "2026-10-01T00:00:00Z" }))
      assert.is_false(match("time>2026-10-22", { time = "yesterday" }))
      assert.is_false(match("time>2026-10-22", {}))
    end)

    it("should keep numeric comparisons for numbers", function()
      assert.is_true(match("ts>1760000000", { ts = 1760619024 }))
      assert.is_true(match("status>=500", { status = 502 }))
    end)
  end)

  local row = { status = 502, path = "/api/licence-checks", level = "ERROR", msg = "request completed" }

  it("should AND space-separated terms", function()
    assert.is_true(match("status>=500 path=/api/licence-checks", row))
    assert.is_false(match("status>=500 path=/other", row))
  end)

  it("should bind AND tighter than OR", function()
    assert.is_true(match("level=INFO OR status>=500 path~licence", row))
    assert.is_false(match("level=INFO OR status<500 path~licence", row))
  end)

  it("should AND separate lines", function()
    assert.is_false(match({ "status>=500", "-path=/api/licence-checks" }, row))
  end)

  it("should compare numbers numerically and strings by text", function()
    assert.is_true(match("status=502", row))
    assert.is_true(match('status="502"', row))
    assert.is_false(match("status>abc", row))
  end)

  it("should treat missing fields as no match and negation as match", function()
    assert.is_false(match("trace_id=x", row))
    assert.is_true(match("-trace_id=x", row))
  end)

  it("should match level case-insensitively", function()
    assert.is_true(match("level=error", row))
  end)

  it("should support quoted values, OR as a value, regex and bare terms", function()
    assert.is_true(match('msg="request completed"', row))
    assert.is_false(match('msg="OR"', row))
    assert.is_true(match("path~^/api/lic", row))
    assert.is_true(match("timeout", row, "upstream timeout after 3s"))
  end)

  it("should read \\n inside a quoted value as a newline", function()
    assert.is_true(match('msg="a\\nb"', { msg = "a\nb" }))
    assert.is_false(match('msg="a\\nb"', { msg = "a\\nb" }))
  end)

  it("should report and skip invalid lines", function()
    local pred, errors = filter.compile({ "status>=500", 'msg="unterminated', "path~\\(" })
    assert.are.equal(2, #errors)
    assert.are.equal(2, errors[1].lnum)
    assert.is_true(pred(ctx(row)))
  end)

  it("should ignore blank lines and match everything when no line is valid", function()
    assert.is_true(match({ "", "  " }, row))
    assert.is_true(match({}, row))
  end)

  it("should compare table values by encoded text and never equal a scalar", function()
    local fields = { tags = { "a", "b" } }
    assert.is_true(match("tags~b", fields))
    assert.is_false(match("tags=a", fields))
    assert.is_true(match("tags!=a", fields))
  end)

  it("should reject dangling OR", function()
    local _, err = filter.parse("a OR")
    assert.is_truthy(err)
  end)

  describe("AND and OR lines", function()
    it("should continue the group above with an OR line and start a new one with AND or no prefix", function()
      local groups = filter.groups({ "a=1", "OR a=2", "", "AND b=1", "c=1", "OR c=2 d=1" })

      assert.are.same({
        { text = "a=1 OR a=2", first = 1, last = 2 },
        { text = "b=1", first = 4, last = 4 },
        { text = "c=1 OR c=2 d=1", first = 5, last = 6 },
      }, groups)
    end)

    it("should AND the groups and OR the lines inside one", function()
      local lines = { "a=1", "AND b=2", "OR c=3" }

      assert.is_true(match(lines, { a = 1, b = 2 }))
      assert.is_true(match(lines, { a = 1, c = 3 }))
      assert.is_false(match(lines, { b = 2, c = 3 }))
    end)

    it("should take AND inside a line as a space", function()
      assert.is_true(match("a=1 AND b=2", { a = 1, b = 2 }))
      assert.is_false(match("a=1 AND b=2", { a = 1 }))
      assert.is_true(match("a=1 AND b=2 OR c=3", { c = 3 }))
      assert.is_truthy(select(2, filter.parse("AND a=1")))
    end)

    it("should report a failed group once with all its lines", function()
      local _, errors = filter.compile({ "OR a=1", "x=1", "OR y~\\(", "OR z=1" })

      assert.are.same({ lnum = 1, last = 1 }, { lnum = errors[1].lnum, last = errors[1].last })
      assert.are.same({ lnum = 2, last = 4 }, { lnum = errors[2].lnum, last = errors[2].last })
    end)

    it("should write every operator out", function()
      assert.are.same(
        { "a=1", "AND b=1", "OR c=1", "AND d=1" },
        filter.explicit({ "AND a=1", "b=1", "OR c=1", "AND d=1" })
      )
    end)
  end)

  describe("locate", function()
    it("should give the message and the columns of the part that fails on its own", function()
      assert.are.same({ "invalid regex `\\(`", 4, 10 }, { filter.locate("a=1 msg~\\(") })
      assert.are.same({ "unterminated quote", 4, 12 }, { filter.locate('AND a="x y z') })
      assert.are.same({ "empty alternative", 4, 6 }, { filter.locate("a=1 OR") })
      assert.are.same({ "nothing before AND", 3, 6 }, { filter.locate("OR AND a=1") })
    end)

    it("should give nil for a line that parses on its own", function()
      assert.is_nil(filter.locate("OR a=1"))
      assert.is_nil(filter.locate("AND a=1 OR b=2"))
    end)
  end)

  describe("facet_of", function()
    it("should give the field and values of a line of field=value alternatives on one field", function()
      assert.are.same({ "status", { "500" } }, { filter.facet_of("status=500") })
      assert.are.same({ "status", { "500", "502" } }, { filter.facet_of("status=500 OR status=502") })
      assert.are.same({ "msg", { "a b", 'say "hi"' } }, { filter.facet_of('msg="a b" OR msg="say \\"hi\\""') })
    end)

    it("should give nil for any other line", function()
      for _, line in ipairs({ "a=1 b=2", "a=1 OR b=2", "-a=1", "a>1", "a~x", "boom", "a=" .. '"' }) do
        assert.is_nil(filter.facet_of(line), line)
      end
    end)

    it("should read back the values clause wrote", function()
      local values = { "500", "a b", 'q"uote', "back\\slash", "new\nline", "" }
      local clauses = vim.tbl_map(function(value)
        return filter.clause("k\ney", value)
      end, values)

      assert.are.same({ "k\ney", values }, { filter.facet_of(table.concat(clauses, " OR ")) })
    end)
  end)
end)
