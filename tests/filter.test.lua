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
end)
