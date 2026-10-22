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
end)
