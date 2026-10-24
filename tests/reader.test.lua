local reader = require("jlog.parse.reader")

---Call `read` until it is done, at most `limit` times.
local function read_all(read, entries, limit)
  for _ = 1, limit do
    if not read(entries) then
      return
    end
  end
  error("reader never finished")
end

describe("reader.source", function()
  local chunk_size = reader.chunk_size

  after_each(function()
    reader.chunk_size = chunk_size
  end)

  it("should read chunk_size lines per call when no count is given", function()
    local text = '{"a":1}\n{"a":2}\n{"a":3}\n{"a":4}\n{"a":5}\n'
    local read = reader.source(text, "jsonl", "none", 0)
    local entries = {}
    local fraction

    reader.chunk_size = 2
    fraction = read(entries)

    assert.are.equal(2, #entries)
    assert.is_true(fraction > 0 and fraction < 1)

    read_all(read, entries, 10)
    assert.are.equal(5, #entries)
  end)

  it("should sort an unordered loki export by timestamp once read", function()
    local text = "["
      .. '{"line":"c","timestamp":"1792157405000000003","fields":{}},'
      .. '{"line":"a","timestamp":"1792157405000000001","fields":{}},'
      .. '{"line":"b","timestamp":"1792157405000000002","fields":{}}'
      .. "]"
    local read = reader.source(text, "loki", "none", 0)
    local entries = {}

    read_all(read, entries, 10)

    assert.are.same(
      { 2, 3, 1 },
      vim.tbl_map(function(entry)
        return entry.src
      end, entries)
    )
  end)
end)
