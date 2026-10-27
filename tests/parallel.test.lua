local facets = require("jlog.query.facets")
local parallel = require("jlog.parse.parallel")
local workers = require("jlog.worker")

local gen = dofile("bench/gen.lua")

---Run a reader to completion the way load_rest does: a first screen of 200 lines, then count == nil calls.
local function load(text, threaded)
  local entries = {}
  local counter = facets.counter()
  local read = parallel.line_reader(text, 1, 1, #text)
  local fraction, waiting
  local give_up = vim.uv.now() + 5000
  local function count_entry(entry, decoded)
    facets.count_entry(counter, entry, decoded)
  end
  local function merge_fields(fields)
    facets.merge(counter, fields)
  end

  workers.disabled = not threaded or nil
  fraction = read(entries, count_entry, 200)
  -- bounded, so a load that never finishes fails instead of hanging
  while fraction and vim.uv.now() < give_up do
    fraction, waiting = read(entries, count_entry, nil, merge_fields)
    if waiting then
      vim.wait(10)
    end
  end

  return entries, facets.result(counter, 10)
end

---@param left table facets.result
---@param right table facets.result
local function assert_same_counts(left, right)
  local others = {}

  for _, field in ipairs(right) do
    others[field.name] = field
  end
  for _, field in ipairs(left) do
    if not field.estimated and not others[field.name].estimated then
      assert.are.same(field, others[field.name])
    end
  end
end

describe("parallel", function()
  local chunk_bytes = parallel.chunk_bytes
  local min_bytes = parallel.min_bytes
  local run = workers.run
  local in_flight = workers.in_flight
  local stall_ms = workers.stall_ms

  before_each(function()
    parallel.min_bytes = 0
    parallel.chunk_bytes = 4096
  end)
  after_each(function()
    parallel.chunk_bytes = chunk_bytes
    parallel.min_bytes = min_bytes
    workers.disabled = nil
    workers.run = run
    workers.in_flight = in_flight
    workers.stall_ms = stall_ms
  end)

  it("should build the same entries and counts as a main-thread load", function()
    local text = table.concat(gen.nested_lines(3000), "\n")
    local base_entries, base_counts = load(text, false)
    local entries, counts = load(text, true)

    assert.is_true(vim.deep_equal(base_entries, entries))
    assert.are.equal(#base_counts, #counts)
    assert_same_counts(base_counts, counts)
  end)

  it("should append a finished chunk a bounded slice per call", function()
    local text = table.concat(gen.nested_lines(3000), "\n")
    local read = parallel.line_reader(text, 1, 1, #text)
    local entries = {}
    local fraction, waiting, before

    parallel.chunk_bytes = #text
    read(entries, nil, 200)
    before = #entries
    repeat
      fraction, waiting = read(entries, nil, nil, nil)
      if waiting then
        vim.wait(10)
      end
    until not waiting

    assert.is_not_nil(fraction)
    assert.is_true(#entries > before)
    assert.is_true(#entries - before <= 500)
  end)

  it("should attach continuation lines across a chunk boundary", function()
    local json_line = '{"level":"error","msg":"panic"}'
    local filler = {}
    local text, entries, panic

    for index = 1, 220 do
      filler[index] = '{"n":' .. index .. "}"
    end
    text = table.concat(filler, "\n") .. "\n" .. json_line .. "\n"
    -- the first screen reads 200 lines; the first chunk then ends right after the panic line's newline
    parallel.chunk_bytes = #text - (#table.concat(filler, "\n", 1, 200) + 1) - 2
    text = text .. "goroutine 1 [running]:\nmain.handle(0xc000123456)\n" .. table.concat(filler, "\n")
    entries = load(text, true)

    for _, entry in ipairs(entries) do
      if entry.raw == json_line then
        panic = entry
      end
    end
    assert.are.same({ "goroutine 1 [running]:", "main.handle(0xc000123456)" }, panic.cont)
  end)

  it("should load CRLF lines and a last line without a newline like the main thread", function()
    local text = table.concat(gen.nested_lines(1000), "\r\n")

    assert.is_true(vim.deep_equal(load(text, false), load(text, true)))
  end)

  it("should fall back to the main thread when a job fails", function()
    local text = table.concat(gen.nested_lines(1000), "\n")
    local calls = 0

    workers.run = function(job, payload, on_result)
      calls = calls + 1
      if calls == 2 then
        vim.defer_fn(function()
          on_result("boom", nil)
        end, 0)

        return
      end
      run(job, payload, on_result)
    end

    assert.is_true(vim.deep_equal(load(text, false), load(text, true)))
    assert.is_true(calls >= 2)
  end)

  it("should load on the main thread when workers are unavailable", function()
    local text = table.concat(gen.nested_lines(1000), "\n")
    local calls = 0
    local base = load(text, false)

    workers.run = function()
      calls = calls + 1
    end

    assert.is_true(vim.deep_equal(base, load(text, false)))
    assert.are.equal(0, calls)
  end)

  it("should report waiting and append nothing when the shared cap is full of other jobs", function()
    local text = table.concat(gen.nested_lines(1000), "\n")
    local read = parallel.line_reader(text, 1, 1, #text)
    local entries = {}
    local fraction, waiting

    workers.in_flight = function()
      return 99
    end
    fraction, waiting = read(entries, nil, nil)

    assert.is_true(waiting)
    assert.is_not_nil(fraction)
    assert.are.equal(0, #entries)
  end)
  it("should finish on the main thread when a chunk never comes back", function()
    local text = table.concat(gen.nested_lines(1000), "\n")
    local base = load(text, false)
    local read = parallel.line_reader(text, 1, 1, #text)
    local entries = {}
    local late = {}
    local give_up = vim.uv.now() + 5000
    local fraction, waiting, size

    workers.disabled = nil
    workers.stall_ms = 50
    workers.run = function(job, payload, on_result)
      late[#late + 1] = function()
        on_result(nil, require("jlog.worker.jobs")[job](payload))
      end
    end
    fraction = read(entries, nil, 200)
    while fraction and vim.uv.now() < give_up do
      fraction, waiting = read(entries, nil, nil)
      if waiting then
        vim.wait(10)
      end
    end
    size = #entries
    for _, deliver in ipairs(late) do
      deliver()
    end
    read(entries, nil, nil)

    assert.is_nil(fraction)
    assert.is_true(#late > 0)
    assert.is_true(vim.deep_equal(base, entries))
    assert.are.equal(size, #entries)
  end)

  it("should finish on the main thread when no worker slot frees up", function()
    local text = table.concat(gen.nested_lines(1000), "\n")
    local base = load(text, false)

    workers.stall_ms = 50
    workers.in_flight = function()
      return 99
    end

    assert.is_true(vim.deep_equal(base, load(text, true)))
  end)
end)
