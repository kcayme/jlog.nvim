local gen = dofile("bench/gen.lua")
local pages = require("jlog.parse.pages")
local source = require("jlog.parse.source")

local OPTS = { size = 10, overlap = 2 }

local function numbered_lines(count)
  local lines = {}

  for index = 1, count do
    lines[index] = string.format('{"n":%d}', index)
  end

  return lines
end

local function full_index(text, format, opts, from_end)
  local index = pages.new(text, format, opts, from_end)

  while not index:scan(0) do
  end

  return index
end

---Entries of a page's byte range, read with the loader that will read it in the workspace.
local function page_entries(text, format, range)
  local slice = text:sub(range.first, range.last)
  local entries = {}

  if format == "jsonl" then
    source.append_lines(entries, vim.split(slice, "\n", { plain = true }), range.first_src)

    return entries
  end
  if range.first_src == 1 then
    slice = "[" .. slice
  end

  return (source.read_elements(slice .. "]", 1, math.huge, format, range.first_src))
end

---The page's own entries: those whose `src` falls in its core.
local function core_entries(text, format, range)
  local core_first = range.core_first_line or range.core_first_element
  local core_last = range.core_last_line or range.core_last_element

  return vim.tbl_filter(function(entry)
    return entry.src >= core_first and entry.src <= core_last
  end, page_entries(text, format, range))
end

local function all_entries(text, format)
  local entries = {}

  if format == "jsonl" then
    source.append_lines(entries, vim.split(text, "\n", { plain = true }), 1)

    return entries
  end

  return (source.read_elements(text, 1, math.huge, format, 1))
end

local function entry_key(entry)
  return entry.raw .. "\0" .. table.concat(entry.cont or {}, "\n")
end

---Core entries of every page, in file order.
local function core_keys(text, format, index, from_end)
  local keys = {}
  local count = index:count()
  local page

  for step = 1, count do
    page = from_end and count - step + 1 or step
    for _, entry in ipairs(core_entries(text, format, index:range(page))) do
      keys[#keys + 1] = entry.src .. "\0" .. entry_key(entry)
    end
  end

  return keys
end

describe("pages", function()
  it("should keep a file of exactly size entries on one page and split one more", function()
    assert.are.equal(1, full_index(table.concat(numbered_lines(10), "\n"), "jsonl", OPTS, true):count())
    assert.are.equal(2, full_index(table.concat(numbered_lines(11), "\n"), "jsonl", OPTS, true):count())
  end)

  it("should number pages from the newest end", function()
    local text = table.concat(numbered_lines(25), "\n") .. "\n"
    local index = full_index(text, "jsonl", OPTS, true)
    local first_core = core_entries(text, "jsonl", index:range(1))
    local last_core = core_entries(text, "jsonl", index:range(3))

    assert.are.equal(3, index:count())
    assert.are.equal('{"n":16}', first_core[1].raw)
    assert.are.equal('{"n":25}', first_core[#first_core].raw)
    assert.are.equal('{"n":1}', last_core[1].raw)
    assert.are.equal('{"n":5}', last_core[#last_core].raw)
  end)

  it("should not split an entry from its continuation lines", function()
    local lines = numbered_lines(17)
    local text, index, core

    -- line 11, the 10th from the end, continues the entry on line 9
    table.insert(lines, 10, "goroutine 1 [running]:")
    table.insert(lines, 11, "main.main()")
    table.insert(lines, 12, "\tmain.go:12")
    text = table.concat(lines, "\n")
    index = full_index(text, "jsonl", OPTS, true)
    core = core_entries(text, "jsonl", index:range(1))

    assert.are.equal('{"n":9}', core[1].raw)
    assert.are.same({ "goroutine 1 [running]:", "main.main()", "\tmain.go:12" }, core[1].cont)
    core = core_entries(text, "jsonl", index:range(2))
    assert.are.equal('{"n":8}', core[#core].raw)
  end)

  it("should include overlap from neighbours", function()
    local text = table.concat(numbered_lines(25), "\n")
    local range = full_index(text, "jsonl", OPTS, true):range(2)
    local entries = page_entries(text, "jsonl", range)

    assert.are.equal(14, #entries)
    assert.are.equal(4, range.first_src)
    assert.are.equal(6, range.core_first_line)
    assert.are.equal(15, range.core_last_line)
    assert.are.equal('{"n":4}', entries[1].raw)
    assert.are.equal(4, entries[1].src)
    assert.are.equal('{"n":17}', entries[#entries].raw)
  end)

  it("should index in steps within a deadline", function()
    local text = table.concat(numbered_lines(20000), "\n")
    local index = pages.new(text, "jsonl", OPTS, true)
    local calls = 0
    local done = false
    local known_early = false

    while not done do
      done = index:scan(0)
      calls = calls + 1
      known_early = known_early or (not done and index:known() >= 1)
      assert.is_nil(not done and index:count() or nil)
    end

    -- a line count then a walk back, each at least 1024 lines a call
    assert.is_true(calls > 2)
    assert.is_true(calls <= 2 * math.ceil(20000 / 1024) + 1)
    assert.is_true(known_early)
    assert.are.equal(2000, index:count())
    assert.are.equal(2000, index:known())
  end)

  it("should index a newest-first loki array from the start", function()
    local text = gen.loki_text(25)
    local index = pages.new(text, "loki", OPTS, false)
    local whole = all_entries(text, "loki")
    local range, entries

    while index:known() < 1 do
      index:scan(0)
    end
    range = index:range(1)
    entries = page_entries(text, "loki", range)
    assert.are.equal(1, range.first_src)
    assert.are.equal(1, range.core_first_element)
    assert.are.equal(10, range.core_last_element)
    assert.are.equal(12, #entries)
    assert.are.equal(whole[1].raw, entries[1].raw)
    assert.are.equal(whole[12].raw, entries[12].raw)

    while not index:scan(0) do
    end
    assert.are.equal(3, index:count())
    range = index:range(3)
    entries = page_entries(text, "loki", range)
    assert.are.equal(19, range.first_src)
    assert.are.equal(21, range.core_first_element)
    assert.are.equal(25, range.core_last_element)
    assert.are.equal(whole[19].raw, entries[1].raw)
    assert.are.equal(19, entries[1].src)
    assert.are.equal(whole[25].raw, entries[#entries].raw)
  end)

  it("should give every entry to exactly one page core when parsed with the loaders", function()
    local tricky = '[ {"s":"],\\"[{"} , [1,[2,"\\\\"]],"a,b",  {"t":"\\\\\\"}"}, 3 ,null,{"u":{"v":[]}},'
      .. '"x" ,true, {"line":"{\\"a\\":1}"}, 4, 5, 6, 7 ]\n'
    local cases = {
      { text = table.concat(gen.jsonl_lines(237), "\r\n") .. "\r\n\r\n", format = "jsonl" },
      { text = "banner\n\nplain\n" .. table.concat(gen.jsonl_lines(120), "\n"), format = "jsonl" },
      { text = gen.loki_text(83), format = "loki" },
      { text = tricky, format = "array" },
    }
    local opts = { size = 7, overlap = 3 }
    local expected, index

    for _, case in ipairs(cases) do
      expected = vim.tbl_map(function(entry)
        return entry.src .. "\0" .. entry_key(entry)
      end, all_entries(case.text, case.format))
      for _, from_end in ipairs({ true, false }) do
        index = full_index(case.text, case.format, opts, from_end)
        assert.is_true(index:count() > 1)
        assert.are.same(expected, core_keys(case.text, case.format, index, from_end))
      end
    end
  end)
end)
