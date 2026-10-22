local json = require("jlog.parse.json")

describe("json.parse", function()
  it("should keep key order, duplicate keys and exact number literals", function()
    local node = json.parse_all('{"ts":"x","b":12345678901234567890,"a":1,"a":2,"f":-1.5e3}')
    assert.are.same({ "ts", "b", "a", "a", "f" }, node.keys)
    assert.are.equal("12345678901234567890", node.vals[2].lit)
    assert.are.equal("-1.5e3", node.vals[5].lit)
  end)

  it("should decode escapes in strings and keep the literal", function()
    local node = json.parse_all('{"m":"he said \\"hi\\"\\n\\u00e9"}')
    assert.are.equal('he said "hi"\né', node.vals[1].str)
    assert.are.equal('"he said \\"hi\\"\\n\\u00e9"', node.vals[1].lit)
  end)

  it("should return offsets and the position after the value", function()
    local node, after = json.parse('  [1, {"a":null}] tail')
    assert.are.equal(3, node.s)
    assert.are.equal(17, node.e)
    assert.are.equal(18, after)
    assert.are.equal("null", node.vals[2].vals[1].t)
  end)

  it("should fail on invalid input", function()
    assert.is_nil(json.parse_all('{"a":1'))
    assert.is_nil(json.parse_all('{"a":1} x'))
    assert.is_nil(json.parse_all("ERROR something broke"))
  end)
end)

describe("json.find and unwrap", function()
  it("should find JSON after a text prefix", function()
    local node, prefix = json.find('API error: 500 - {"code":500,"error":"x"}')
    assert.are.equal("API error: 500 - ", prefix)
    assert.are.same({ "code", "error" }, node.keys)
  end)

  it("should unwrap double and triple encoded strings up to max_depth", function()
    local text = '{"line":"{\\"err\\":\\"API error: 500 - {\\\\\\"code\\\\\\":500}\\"}"}'
    local node = json.unwrap(json.parse_all(text), 4)
    local line = node.vals[1]
    assert.are.equal("", line.prefix)
    local err = line.inner.vals[1]
    assert.are.equal("API error: 500 - ", err.prefix)
    assert.are.equal("500", err.inner.vals[1].lit)
    assert.is_nil(json.unwrap(json.parse_all(text), 1).vals[1].inner.vals[1].inner)
  end)

  it("should leave non-JSON strings alone", function()
    local node = json.unwrap(json.parse_all('{"m":"see {braces}"}'), 4)
    assert.is_nil(node.vals[1].inner)
  end)
end)
