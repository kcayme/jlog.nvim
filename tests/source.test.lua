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

describe("source.read_elements", function()
  local function read_all(text, format, count)
    local entries, pos, chunk, err = {}, 1, nil, nil

    while pos do
      chunk, pos, err = source.read_elements(text, pos, count, format, #entries + 1)
      assert.is_nil(err)
      vim.list_extend(entries, chunk)
    end

    return entries
  end

  local function element_text(raws)
    return "[" .. table.concat(raws, ",") .. "]"
  end

  it("should read loki elements in chunks with the same entries as a full build", function()
    local text = read("loki.json")
    local built = source.build(text, "loki")
    local chunked = read_all(text, "loki", 2)

    table.sort(chunked, function(left, right)
      if #left.ts ~= #right.ts then
        return #left.ts < #right.ts
      end
      if left.ts ~= right.ts then
        return left.ts < right.ts
      end

      return left.src < right.src
    end)
    assert.are.equal(#built, #chunked)
    for index, entry in ipairs(built) do
      for _, field in ipairs({ "src", "raw", "body", "ts", "labels", "json_at" }) do
        assert.are.same(entry[field], chunked[index][field])
      end
    end
  end)

  it("should read loki edge cases the same as a full build when the fast decode declines them", function()
    local text = element_text({
      ' {"line":"{\\"a\\":1}\\n","timestamp":"1","fields":{"app":"x"}} ',
      '{"line":"caf\\u00e9","timestamp":"2","fields":{"app":"x"}}',
      '{"line":"one","line":"two","timestamp":"3","fields":{}}',
      '{"line":"n","timestamp":"4","fields":{"port":8080,"line":"l"}}',
      '{"line":"n","timestamp":"5","fields":null}',
      '{"line":"n","timestamp":6}',
      '{"line":"tab\\there","timestamp":"7"}\n',
    })
    local built = source.build(text, "loki")
    local chunked = read_all(text, "loki", 3)

    assert.are.equal(#built, #chunked)
    for index, entry in ipairs(built) do
      for _, field in ipairs({ "src", "raw", "body", "ts", "labels", "json_at" }) do
        assert.are.same(entry[field], chunked[index][field])
      end
    end
  end)

  it("should read array elements and report a broken array", function()
    local entries = read_all(read("array.json"), "array", 1)
    local _, _, err

    assert.are.equal(2, #entries)
    assert.are.equal(2, entries[2].src)
    assert.are.equal(1, entries[1].json_at)
    _, _, err = source.read_elements('{"a":1}', 1, 10, "array", 1)
    assert.is_truthy(err)
    _, _, err = source.read_elements('[{"a":1},{"a', 1, 10, "array", 1)
    assert.is_truthy(err)
    assert.are.same({}, (source.read_elements(" [ ] ", 1, 10, "array", 1)))
  end)

  it("should detect element order", function()
    local raws = vim.tbl_map(function(entry)
      return entry.raw
    end, read_all(read("loki.json"), "loki", 100))
    local half = math.floor(#raws / 2)
    local reversed = vim.fn.reverse(vim.deepcopy(raws))
    local shuffled = vim.list_extend(vim.fn.reverse(vim.list_slice(raws, 1, half)), vim.list_slice(raws, half + 1))

    assert.are.equal("desc", source.element_order(read("loki.json"), "loki"))
    assert.are.equal("asc", source.element_order(element_text(reversed), "loki"))
    assert.are.equal("none", source.element_order(element_text(shuffled), "loki"))
    assert.are.equal("none", source.element_order(read("array.json"), "array"))
  end)
end)
