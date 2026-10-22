local source = require("jlog.parse.source")
local function read(name)
  return table.concat(vim.fn.readfile("tests/fixtures/" .. name, "b"), "\n")
end

describe("source.build", function()
  it("should build jsonl entries with prefixes, continuation lines and CRLF stripped", function()
    local entries = source.build(read("app.jsonl"), "jsonl")
    assert.are.equal(4, #entries)
    assert.is_nil(entries[1].json_at) -- banner before first JSON entry is a plain entry
    assert.are.equal(26, entries[2].json_at)
    assert.are.same({ "goroutine 1 [running]:", "main.main()" }, entries[3].cont)
    assert.are.equal(7, entries[4].src)
    assert.is_nil(entries[4].raw:find("\r"))
  end)

  it("should build loki entries oldest first with labels and exact raw elements", function()
    local text = read("loki.json")
    local entries = source.build(text, "loki")
    assert.is_true(#entries >= 30)
    for i = 2, #entries do
      local a, b = entries[i - 1].ts, entries[i].ts
      assert.is_true(#a < #b or (#a == #b and a <= b))
    end
    local first = entries[1]
    assert.is_truthy(first.labels.pod)
    assert.is_truthy(text:find(first.raw, 1, true))
    assert.is_nil(first.body:find("\n$"))
  end)

  it("should keep plain and empty loki lines as plain entries", function()
    local plain = vim.tbl_filter(function(e)
      return e.json_at == nil
    end, source.build(read("loki.json"), "loki"))
    assert.are.equal(4, #plain)
  end)

  it("should split arrays into elements", function()
    local entries = source.build(read("array.json"), "array")
    assert.are.equal(2, #entries)
    assert.are.equal(1, entries[1].json_at)
  end)

  it("should return no entries for empty text", function()
    assert.are.same({}, source.build("", "jsonl"))
  end)
end)
