local render = require("jlog.ui.render")
local highlights = require("jlog.ui.highlights")
local source = require("jlog.parse.source")
local opts = require("jlog.config").setup()
local function one(text)
  return source.build(text, "jsonl")[1]
end
local function spans_of(spans, group)
  return vim.tbl_filter(function(span)
    return span[3] == group
  end, spans)
end

describe("render.compact", function()
  it("should render time, padded level, message, then remaining fields in source order", function()
    local lines, spans = render.compact(
      one('{"time":"2026-10-16T12:50:24.970389138Z","level":"ERROR","msg":"failed","event":"x","company_id":15}'),
      opts
    )
    assert.are.equal("12:50:24.970 ERROR failed  event=x company_id=15", lines[1])
    assert.are.same({ 13, 18, "JLogLevelError" }, spans_of(spans[1], "JLogLevelError")[1])
    assert.are.same({ 0, 12, "JLogTime" }, spans_of(spans[1], "JLogTime")[1])
    assert.are.same(
      { { 27, 33, highlights.field_group("event") } },
      spans_of(spans[1], highlights.field_group("event"))
    )
    assert.are.same(
      { { 35, 46, highlights.field_group("company_id") } },
      spans_of(spans[1], highlights.field_group("company_id"))
    )
    assert.are.same({ { 33, 34, "JLogValue" }, { 46, 48, "JLogValue" } }, spans_of(spans[1], "JLogValue"))
  end)

  it("should pad short levels and map unknown levels to trace", function()
    local lines, spans = render.compact(one('{"level":"info","msg":"m"}'), opts)
    assert.are.equal("INFO  m", lines[1])
    assert.are.same({ 0, 4, "JLogLevelInfo" }, spans_of(spans[1], "JLogLevelInfo")[1])
    _, spans = render.compact(one('{"level":"notice","msg":"m"}'), opts)
    assert.are.equal(1, #spans_of(spans[1], "JLogLevelTrace"))
  end)

  it("should separate long levels, keep message spaces and pad before fields", function()
    assert.are.equal("WARNING m", render.compact(one('{"level":"WARNING","msg":"m"}'), opts)[1])
    assert.are.equal("m ", render.compact(one('{"msg":"m "}'), opts)[1])
    assert.are.equal("INFO  a=1", render.compact(one('{"level":"INFO","a":1}'), opts)[1])
    assert.are.equal("DEBUG  a=1", render.compact(one('{"level":"DEBUG","a":1}'), opts)[1])
    assert.are.equal("a=1", render.compact(one('{"a":1}'), opts)[1])
  end)

  it("should keep big integers exact and flatten nested objects", function()
    local lines = render.compact(one('{"msg":"m","big":12345678901234567890,"req":{"method":"GET"}}'), opts)
    assert.are.equal("m  big=12345678901234567890 req.method=GET", lines[1])
  end)

  it("should show prefixed embedded JSON collapsed and escape newlines", function()
    local lines = render.compact(one('{"msg":"a\\nb","err":"API error: 500 - {\\"code\\":500}"}'), opts)
    assert.are.equal("a\\nb  err=API error: 500 - {…}", lines[1])
  end)

  it("should flatten unprefixed embedded JSON like an object", function()
    local lines = render.compact(one('{"msg":"m","body":"{\\"code\\":500,\\"ok\\":false}"}'), opts)
    assert.are.equal("m  body.code=500 body.ok=false", lines[1])
  end)

  it("should escape newlines in keys", function()
    local lines = render.compact(one('{"msg":"m","a\\nb":1}'), opts)
    assert.are.equal("m  a\\nb=1", lines[1])
  end)

  it("should show arrays verbatim", function()
    local lines = render.compact(one('{"msg":"m","tags":["a", 1]}'), opts)
    assert.are.equal('m  tags=["a", 1]', lines[1])
  end)

  it("should format the loki timestamp in UTC when there is no time field", function()
    local e = one('{"msg":"m"}')
    e.ts = "1760619024970389138"
    assert.are.equal("12:50:24.970 m", render.compact(e, opts)[1])
  end)

  it("should pad or cut the time fraction to milliseconds", function()
    local function time_of(value)
      return render.compact(one('{"time":"' .. value .. '"}'), opts)[1]
    end
    assert.are.equal("12:50:24.900", time_of("2026-10-16T12:50:24.9Z"))
    assert.are.equal("12:50:24.000", time_of("2026-10-16T12:50:24Z"))
    assert.are.equal("12:50:24.000", time_of("2026-10-16T12:50:24.Z"))
    assert.are.equal("12:50:24.123", time_of("2026-10-16T12:50:24.123456+02:00"))
    assert.are.equal("12:50:24.120", time_of("2026-10-16 T12:50:2412"))
  end)

  it("should show unrecognised time values as-is", function()
    assert.are.equal("yesterday m", render.compact(one('{"time":"yesterday","msg":"m"}'), opts)[1])
  end)

  it("should keep the line prefix", function()
    local lines = render.compact(one('2026-10-22T10:00:01Z {"msg":"m"}'), opts)
    assert.are.equal("2026-10-22T10:00:01Z m", lines[1])
  end)

  it("should render plain entries and continuation lines as-is", function()
    local entries = source.build('banner\n{"msg":"x"}\ntrace line', "jsonl")
    local _, spans = render.compact(entries[2], opts)
    assert.are.same({ "banner" }, (render.compact(entries[1], opts)))
    assert.are.same({ "x", "trace line" }, (render.compact(entries[2], opts)))
    assert.are.same({ { 0, 10, "JLogPlain" } }, spans[2])
  end)

  it("should return the same lines and no spans when lines_only is set", function()
    local entries = source.build('banner\n{"level":"INFO","msg":"x","a":{"b":1}}\ntrace line', "jsonl")
    for _, entry in ipairs(entries) do
      local lines, spans = render.compact(entry, opts, true)
      assert.are.same(render.compact(entry, opts), lines)
      assert.is_nil(spans)
    end
  end)

  it("should split plain multi-line bodies so no line holds a newline", function()
    local lines = render.compact({ src = 1, raw = "", body = "a\nb" }, opts)
    assert.are.same({ "a", "b" }, lines)
  end)
end)

describe("render.expanded", function()
  it("should indent JSON in source order with unwrapped values nested", function()
    local lines = render.expanded(one('{"b":1,"a":"{\\"x\\":true}"}'), opts)
    assert.are.same({ "{", '  "b": 1,', '  "a": {', '    "x": true', "  }", "}" }, lines)
  end)

  it("should show the prefix before an unwrapped object", function()
    local lines = render.expanded(one('{"err":"API error: 500 - {\\"code\\":500}"}'), opts)
    assert.are.equal('  "err": "API error: 500 - " {', lines[2])
  end)

  it("should keep escapes and highlight values by type", function()
    local lines, spans = render.expanded(one('{"s":"a\\nb","n":null,"l":[1,{}]}'), opts)
    assert.are.same({ "{", '  "s": "a\\nb",', '  "n": null,', '  "l": [', "    1,", "    {}", "  ]", "}" }, lines)
    assert.are.same({ { 2, 5, highlights.field_group("s") }, { 7, 13, "JLogString" } }, spans[2])
    assert.are.same({ { 2, 5, highlights.field_group("n") }, { 7, 11, "JLogNull" } }, spans[3])
  end)

  it("should append loki labels as a labels object", function()
    local e = one('{"msg":"x"}')
    e.labels = { pod = "p1", app = "a" }
    local lines = render.expanded(e, opts)
    assert.are.same({ "{", '  "msg": "x",', '  "labels": {', '    "app": "a",', '    "pod": "p1"', "  }", "}" }, lines)
  end)
end)

describe("render.header", function()
  it("should summarise a group", function()
    local line = render.header({ label = "3c76a3a2e9", idxs = { 1, 2 }, status = 500, method = "POST", path = "/x" })
    assert.are.equal("▾ 3c76a3a2…  2 entries · 500 · POST /x", line)
  end)

  it("should escape newlines in the label and the summary parts", function()
    local line = render.header({ label = "a\nb", idxs = { 1 }, status = "5\n0", method = "GE\nT", path = "/x\ny" })
    assert.are.equal("▾ a\\nb  1 entry · 5\\n0 · GE\\nT /x\\ny", line)
  end)

  it("should show a numeric status exactly", function()
    local line = render.header({ label = "x", idxs = { 1 }, status = 1234567890123456 })
    assert.are.equal("▾ x  1 entry · 1234567890123456", line)
  end)

  it("should omit missing parts and use the singular", function()
    local line, spans = render.header({ label = "(no request_id)", idxs = { 3 } })
    assert.are.equal("▾ (no requ…  1 entry", line)
    assert.are.same({ { 0, #line, "JLogGroupHeader" } }, spans)
  end)
end)

describe("field colors", function()
  it("should color a key by its dotted path, the same on every line and in the expanded view", function()
    local _, first = render.compact(one('{"msg":"m","fc_a":1,"fc_b":{"c":2}}'), opts)
    local _, second = render.compact(one('{"fc_b":{"c":3},"fc_a":2}'), opts)
    local _, expanded = render.expanded(one('{"fc_b":{"c":2}}'), opts)
    local group_a, group_b, group_c =
      highlights.field_group("fc_a"), highlights.field_group("fc_b"), highlights.field_group("fc_b.c")

    assert.are_not.equal(group_a, group_c)
    assert.are.equal(1, #spans_of(first[1], group_a))
    assert.are.equal(1, #spans_of(first[1], group_c))
    assert.are.equal(1, #spans_of(second[1], group_a))
    assert.are.equal(1, #spans_of(second[1], group_c))
    assert.are.equal(group_b, expanded[2][1][3])
    assert.are.equal(group_c, expanded[3][1][3])
  end)

  it("should use one key color when field colors are off", function()
    local single = vim.tbl_deep_extend("force", opts, { view = { field_colors = false } })
    local _, compact = render.compact(one('{"fc_a":1}'), single)
    local _, expanded = render.expanded(one('{"fc_a":1}'), single)

    assert.are.same({ { 0, 5, "JLogKey" }, { 5, 6, "JLogValue" } }, compact[1])
    assert.are.equal("JLogKey", expanded[2][1][3])
  end)
end)

describe("compact styles", function()
  local config = require("jlog.config")
  local detect = require("jlog.parse.detect")

  local function styled(compact, view)
    return config.setup({ compact = compact, view = view })
  end

  local function with_cap(spans)
    return vim.tbl_filter(function(span)
      return span[4] ~= nil
    end, spans)
  end

  after_each(function()
    config.setup()
  end)

  it("should render exactly as before when nothing is configured", function()
    local defaults, plain = styled(nil), styled({ style = "plain" })

    for _, name in ipairs(vim.fn.readdir("tests/fixtures")) do
      local text = table.concat(vim.fn.readfile("tests/fixtures/" .. name), "\n")
      local entries = source.build(text, detect.detect(text, defaults) or "jsonl")

      for index = 1, math.min(5, #entries) do
        local lines, spans = render.compact(entries[index], defaults)
        local plain_lines, plain_spans = render.compact(entries[index], plain)

        assert.are.same(lines, plain_lines)
        assert.are.same(spans, plain_spans)
      end
    end
  end)

  it("should show a pill's value only, colored by status class", function()
    local lines, spans = render.compact(
      one('{"level":"ERROR","msg":"x","status":500}'),
      styled({ fields = { status = { style = "pill" } } })
    )

    assert.are.equal("ERROR x  500", lines[1])
    assert.are.same({ { 9, 12, highlights.badge_of("JLogStatus5xx"), "JLogStatus5xx" } }, with_cap(spans[1]))
  end)

  it("should keep literals and escape newlines inside badges", function()
    local lines = render.compact(one('{"a":1.50,"b":"x\\ny"}'), styled({ style = "inverted" }))

    assert.are.equal("1.50 x\\ny", lines[1])
  end)

  it("should use the format's text and group in every style", function()
    local format = function(ctx)
      return "HTTP " .. ctx.value, "DiagnosticHint"
    end
    local lines, spans =
      render.compact(one('{"status":500}'), styled({ fields = { status = { style = "plain", format = format } } }))

    assert.are.equal("HTTP 500", lines[1])
    assert.are.same({ { 0, 8, "DiagnosticHint" } }, spans[1])
    lines, spans =
      render.compact(one('{"status":500}'), styled({ fields = { status = { style = "pill", format = format } } }))
    assert.are.equal("HTTP 500", lines[1])
    assert.are.same({ { 0, 8, highlights.badge_of("DiagnosticHint"), "DiagnosticHint" } }, spans[1])
  end)

  it("should color a formatted plain field by its key when the format gives no group", function()
    local format = function(ctx)
      return "HTTP " .. ctx.value
    end
    local _, spans = render.compact(
      one('{"level":"ERROR","msg":"x","status":500}'),
      styled({ fields = { status = { style = "plain", format = format } } })
    )

    assert.are.same(
      { { 9, 17, highlights.field_group("status") } },
      spans_of(spans[1], highlights.field_group("status"))
    )
  end)

  it("should escape newlines in a format's text", function()
    local format = function()
      return "a\nb"
    end
    local lines = render.compact(one('{"a":1}'), styled({ fields = { a = { format = format } } }))

    assert.are.equal("a\\nb", lines[1])
  end)

  it("should style nested and collapsed values", function()
    local lines = render.compact(
      one('{"req":{"host":"h"},"list":[1,2]}'),
      styled({ fields = { ["req.host"] = { style = "inverted" }, list = { style = "inverted" } } })
    )

    assert.are.equal("h [1,2]", lines[1])
  end)

  it("should keep the level badge and its alignment in any style", function()
    local lines, spans =
      render.compact(one('{"level":"info","msg":"m"}'), styled({ fields = { level = { style = "pill" } } }))

    assert.are.equal("INFO  m", lines[1])
    assert.are.equal(0, spans[1][1][1])
    assert.are.equal(4, spans[1][1][2])
    assert.are.equal("DiagnosticInfo", spans[1][1][4])
  end)

  it("should fall back to JLogKey's color when field colors are off", function()
    local _, spans = render.compact(one('{"a":1}'), styled({ style = "inverted" }, { field_colors = false }))

    assert.are.same({ { 0, 1, highlights.badge_of("JLogKey") } }, spans[1])
  end)

  it("should not run the global style on time and message", function()
    local lines, spans =
      render.compact(one('{"time":"2026-10-16T12:50:24.970Z","msg":"m"}'), styled({ style = "pill" }))

    assert.are.equal("12:50:24.970 m", lines[1])
    assert.are.same({}, with_cap(spans[1]))
  end)
end)
