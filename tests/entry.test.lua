local entry = require("jlog.parse.entry")
local source = require("jlog.parse.source")
local opts = require("jlog.config").setup()
local function build(text, fmt)
  return source.build(text, fmt or "jsonl")
end

describe("entry", function()
  it("should resolve aliases, nested paths, unwrapped strings and labels", function()
    local e = build('{"message":"hi","severity":"warn","err":"API error: 500 - {\\"code\\":500}"}')[1]
    e.labels, e.ts = { pod = "p1" }, "17"
    local d = entry.decode(e)
    assert.are.equal("hi", entry.get(e, d, "msg", opts))
    assert.are.equal("warn", entry.get(e, d, "level", opts))
    assert.are.equal(500, entry.get(e, d, "err.code", opts))
    assert.are.equal("p1", entry.get(e, d, "labels.pod", opts))
    assert.are.equal("17", entry.get(e, d, "labels._ts", opts))
    assert.is_nil(entry.get(e, d, "missing.path", opts))
  end)

  it("should format numbers exactly and briefly", function()
    assert.are.equal("1234567890123456", entry.text(1234567890123456))
    assert.are.equal("-42", entry.text(-42))
    assert.are.equal("0.1", entry.text(0.1))
    assert.are.equal("0.30000000000000004", entry.text(0.1 + 0.2))
    assert.are.equal("1e+300", entry.text(1e300))
    assert.are.equal("true", entry.text(true))
  end)

  it("should use the last value for duplicate keys when filtering", function()
    local e = build('{"a":1,"a":2}')[1]
    assert.are.equal(2, entry.get(e, entry.decode(e), "a", opts))
  end)

  it("should flatten nested objects to dotted paths", function()
    local e = build('{"req":{"method":"GET","h":{"host":"x"}},"n":1}')[1]
    local flat = entry.flatten(e, entry.decode(e))
    assert.are.equal("GET", flat["req.method"])
    assert.are.equal("x", flat["req.h.host"])
  end)

  it("should return the line prefix with the tree", function()
    local node, prefix = entry.tree(build('2026-10-22T10:00:01Z {"level":"INFO"}')[1], opts)
    assert.are.equal("2026-10-22T10:00:01Z ", prefix)
    assert.are.same({ "level" }, node.keys)
  end)

  it("should round-trip dotted label keys through flatten and get", function()
    local e = build('{"a":1}')[1]
    e.labels = { ["app.kubernetes.io/name"] = "api" }
    local flat = entry.flatten(e, entry.decode(e))
    assert.are.equal("api", flat["labels.app.kubernetes.io/name"])
    assert.are.equal("api", entry.get(e, nil, "labels.app.kubernetes.io/name", opts))
  end)

  it("should return ts for labels._ts even without labels", function()
    local e = build('{"a":1}')[1]
    e.ts = "9"
    assert.are.equal("9", entry.get(e, entry.decode(e), "labels._ts", opts))
  end)

  it("should not unwrap strings when unwrap is disabled", function()
    local e = build('{"err":"x {\\"code\\":500}"}')[1]
    local off = vim.tbl_deep_extend("force", opts, { unwrap = { enable = false } })
    assert.is_nil(entry.get(e, entry.decode(e), "err.code", off))
  end)

  it("should return nil for null and prefer a real level key over aliases", function()
    local e = build('{"n":null,"level":"info","severity":"warn"}')[1]
    local d = entry.decode(e)
    assert.is_nil(entry.get(e, d, "n", opts))
    assert.are.equal("info", entry.get(e, d, "level", opts))
  end)
end)
