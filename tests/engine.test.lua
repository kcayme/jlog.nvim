local config = require("jlog.config")
local count_mod = require("jlog.query.count")
local engine_mod = require("jlog.query.engine")
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local filter = require("jlog.query.filter")
local source = require("jlog.parse.source")
local workers = require("jlog.worker")

local TEXT = table.concat({
  '{"status":200,"request_id":"a"}',
  '{"status":500,"request_id":"a"}',
  '{"status":500,"request_id":"b"}',
}, "\n")

describe("engine", function()
  local timing = vim.deepcopy(engine_mod.timing)
  local notify = vim.notify
  local engine

  local function status_500()
    return (filter.compile({ "status=500" }))
  end

  before_each(function()
    vim.notify = function() end
    engine = engine_mod.new({
      key = "test",
      entries = source.build(TEXT, "jsonl"),
      opts = config.setup(),
      state = { filters = {}, reverse = false, expanded = {}, mode = "compact" },
      stored_newest_first = false,
    })
  end)

  after_each(function()
    vim.notify = notify
    engine_mod.timing = vim.deepcopy(timing)
  end)

  it("should report the matching entries in order", function()
    local items, shown

    engine:query(status_500(), nil, function(result, count)
      items, shown = result, count
    end)

    assert.are.same({ { kind = "entry", idx = 2 }, { kind = "entry", idx = 3 } }, items)
    assert.are.equal(2, shown)
  end)

  it("should not decode an entry again for a field an earlier query read", function()
    local decode = entry_model.decode
    local decodes = 0
    local nested = filter.compile({ "req.method=GET" })

    engine.source.entries = source.build('{"req":{"method":"GET"}}\n{"req":{"method":"POST"}}', "jsonl")
    entry_model.decode = function(...)
      decodes = decodes + 1

      return decode(...)
    end
    engine:query(nested, nil, function() end, true)
    engine:query(nested, "req.method", function() end, true)
    entry_model.decode = decode

    assert.are.equal(2, decodes)
  end)

  it("should group by a field", function()
    local items

    engine:query(status_500(), "request_id", function(result)
      items = result
    end)

    assert.are.equal("header", items[1].kind)
    assert.are.equal("a", items[1].group.label)
  end)

  it("should drop a superseded query's result", function()
    local first, second = false, false

    -- more entries than one scan batch, so the first query spans ticks
    engine.source.entries = source.build(string.rep('{"status":500}\n', 1200), "jsonl")
    engine_mod.timing.tick_ns = 0
    engine:query(status_500(), nil, function()
      first = true
    end)
    engine:query(status_500(), nil, function()
      second = true
    end)
    assert.is_true(engine.running)

    assert.is_true(vim.wait(1000, function()
      return second
    end, 10))
    assert.is_false(first)
    assert.is_false(engine.running)
  end)

  it("should not stay running when the filter raises", function()
    local ok = pcall(engine.query, engine, function()
      error("boom")
    end, nil, function() end)

    assert.is_false(ok)
    assert.is_false(engine.running)
  end)

  it("should count the matched entries", function()
    local counter

    engine:query(status_500(), nil, function() end)
    engine:count(function(result)
      counter = result
    end)

    assert.is_true(vim.wait(1000, function()
      return counter ~= nil
    end, 10))
    assert.are.equal(2, counter.fields.status.counts["500"])
    assert.are.equal(counter, engine.counter)
  end)

  it("should count a field whose values are on OR lines as if those lines were off", function()
    local filters = { "status=500", "OR status=200", "AND request_id=b" }
    local counter

    engine = engine_mod.new({
      key = "test",
      entries = source.build(TEXT, "jsonl"),
      opts = config.setup(),
      state = { filters = filters, reverse = false, expanded = {}, mode = "compact" },
      stored_newest_first = false,
    })
    engine:query(filter.compile(filters), nil, function() end)
    engine:count(function(result)
      counter = result
    end)
    assert.is_true(vim.wait(1000, function()
      return counter ~= nil
    end, 10))

    -- status counts the request_id=b entries, request_id the status 500 or 200 ones
    assert.are.same({ ["500"] = 1 }, counter.fields.status.counts)
    assert.are.same({ a = 2, b = 1 }, counter.fields.request_id.counts)
  end)

  it("should skip counting picked fields when asked", function()
    engine.source.state.filters = { "status=500" }
    engine:query(status_500(), nil, function() end, true)

    assert.are.same({}, engine.facet_preds)
    assert.are.same({}, engine.facet_counter.names)
  end)

  it("should count a field with its own filter line as if that line were off", function()
    local counter

    engine = engine_mod.new({
      key = "test",
      entries = source.build(TEXT, "jsonl"),
      opts = config.setup(),
      state = { filters = { "status=500", "request_id=a" }, reverse = false, expanded = {}, mode = "compact" },
      stored_newest_first = false,
    })
    engine:query(filter.compile({ "status=500", "request_id=a" }), nil, function() end)
    engine:count(function(result)
      counter = result
    end)
    assert.is_true(vim.wait(1000, function()
      return counter ~= nil
    end, 10))

    -- status counts the request_id=a entries, request_id the status=500 ones
    assert.are.same({ ["200"] = 1, ["500"] = 1 }, counter.fields.status.counts)
    assert.are.same({ a = 1, b = 1 }, counter.fields.request_id.counts)
  end)

  it(
    "should count an appended entry that misses only a field's own line, also after a query that kept the count",
    function()
      local filters = { "status=500", "request_id=a" }
      local counter, entry
      local function append()
        entry = source.build('{"status":200,"request_id":"a"}', "jsonl")[1]
        engine:count_unmatched_appended({
          raw = entry_model.key(entry),
          get = function(path)
            return entry_model.get(entry, entry_model.decode(entry), path, config.options)
          end,
        })
      end

      engine = engine_mod.new({
        key = "test",
        entries = source.build(TEXT, "jsonl"),
        opts = config.setup(),
        state = { filters = filters, reverse = false, expanded = {}, mode = "compact" },
        stored_newest_first = false,
      })
      engine:query(filter.compile(filters), nil, function() end)
      engine:count(function(result)
        counter = result
      end)
      assert.is_true(vim.wait(1000, function()
        return counter ~= nil
      end, 10))

      append()
      assert.are.equal(2, counter.fields.status.counts["200"])
      -- reverse runs the query again and keeps the finished count
      engine:query(filter.compile(filters), nil, function() end)
      append()
      assert.are.equal(3, counter.fields.status.counts["200"])
    end
  )

  it("should add appended matches to a finished count", function()
    local counter, entry

    engine:query(status_500(), nil, function() end)
    engine:count(function(result)
      counter = result
    end)
    vim.wait(1000, function()
      return counter ~= nil
    end, 10)
    entry = source.build('{"status":500,"request_id":"c"}', "jsonl")[1]
    engine:count_appended(4, entry, entry_model.decode(entry))

    assert.are.equal(3, counter.fields.status.counts["500"])
  end)

  describe("threaded counts", function()
    local run = workers.run
    local in_flight = workers.in_flight
    local defer_fn = vim.defer_fn
    local batch_bytes = count_mod.batch_bytes
    local stall_ms = workers.stall_ms

    local function build_lines()
      local lines = {}

      for index = 1, 5000 do
        lines[index] = ('{"status":%d,"route":"/r%d","n":%d}'):format(
          index % 3 == 0 and 500 or 200,
          index % 7,
          index % 500
        )
      end
      lines[#lines + 1] = "not json at all"

      return table.concat(lines, "\n")
    end

    local function count_all(threaded)
      local counter

      workers.disabled = not threaded or nil
      engine.source.entries = source.build(build_lines(), "jsonl")
      engine:query(function()
        return true
      end, nil, function() end)
      engine:count(function(result)
        counter = result
      end)
      assert.is_true(vim.wait(5000, function()
        return counter ~= nil
      end, 10))

      return facets.result(counter, 5)
    end

    local function exact(list)
      local out = {}

      for _, field in ipairs(list) do
        if not field.estimated then
          out[field.name] = field
        end
      end

      return out
    end

    after_each(function()
      workers.disabled = nil
      workers.run = run
      workers.in_flight = in_flight
      vim.defer_fn = defer_fn
      count_mod.batch_bytes = batch_bytes
      workers.stall_ms = stall_ms
    end)

    it("should count a large match on workers with the same uncapped counts", function()
      local jobs = 0
      local expected, actual

      count_mod.batch_bytes = 4096
      expected = count_all(false)
      workers.run = function(job, payload, on_result)
        jobs = jobs + (job == "count_entries" and 1 or 0)

        return run(job, payload, on_result)
      end
      actual = count_all(true)

      assert.is_true(jobs > 1)
      assert.are.same(exact(expected), exact(actual))
    end)

    it("should not publish a superseded query's counts", function()
      local done = false

      count_mod.batch_bytes = 4096
      engine.source.entries = source.build(build_lines(), "jsonl")
      engine:query(function()
        return true
      end, nil, function() end)
      engine:count(function()
        done = true
      end)
      engine:query(status_500(), nil, function() end)

      assert.is_false(vim.wait(1000, function()
        return done
      end, 10))
    end)

    it("should wait between ticks while other jobs hold every slot, then finish", function()
      local delays = {}
      local counter

      count_mod.batch_bytes = 4096
      engine.source.entries = source.build(build_lines(), "jsonl")
      engine:query(function()
        return true
      end, nil, function() end)
      workers.in_flight = function()
        return 99
      end
      vim.defer_fn = function(callback, delay)
        delays[#delays + 1] = delay

        return defer_fn(callback, delay)
      end
      engine:count(function(result)
        counter = result
      end)
      vim.wait(100, function()
        return false
      end)
      workers.in_flight = in_flight

      assert.is_nil(counter)
      assert.is_true(#delays > 1)
      assert.is_true(delays[#delays] > 0)
      assert.is_true(vim.wait(5000, function()
        return counter ~= nil
      end, 10))
    end)

    it("should count a failed batch on the main thread", function()
      local calls = 0
      local expected, actual

      count_mod.batch_bytes = 4096
      expected = count_all(false)
      workers.run = function(job, payload, on_result)
        calls = calls + 1
        if calls == 2 then
          return vim.defer_fn(function()
            on_result("boom", nil)
          end, 0)
        end

        return run(job, payload, on_result)
      end
      actual = count_all(true)

      assert.is_true(calls > 2)
      assert.are.same(exact(expected), exact(actual))
    end)
    it("should count on the main thread when batches never come back", function()
      local late = {}
      local calls = 0
      local expected, counter, before

      count_mod.batch_bytes = 4096
      expected = count_all(false)
      workers.stall_ms = 50
      workers.run = function(job, payload, on_result)
        late[#late + 1] = function()
          on_result(nil, require("jlog.worker.jobs")[job](payload))
        end
      end
      workers.disabled = nil
      engine:query(function()
        return true
      end, nil, function() end)
      engine:count(function(result)
        calls = calls + 1
        counter = result
      end)
      assert.is_true(vim.wait(5000, function()
        return counter ~= nil
      end, 10))
      before = facets.result(counter, 5)
      for _, deliver in ipairs(late) do
        deliver()
      end
      vim.wait(100)

      assert.is_true(#late > 0)
      assert.are.equal(1, calls)
      assert.are.same(exact(expected), exact(before))
      assert.are.same(before, facets.result(counter, 5))
    end)

    it("should release a stalled batch's entries while its worker never answers", function()
      local pending = {}
      local done = false

      count_mod.batch_bytes = 4096
      engine.source.entries = source.build(build_lines(), "jsonl")
      workers.stall_ms = 50
      -- the transport keeps every callback until its worker answers, as `workers.run` does
      workers.run = function(_, _, on_result)
        pending[#pending + 1] = on_result
      end
      workers.disabled = nil
      engine:query(function()
        return true
      end, nil, function() end)
      engine:count(function()
        done = true
      end)
      assert.is_true(vim.wait(5000, function()
        return done
      end, 10))

      assert.is_true(#pending > 0)
      for _, on_result in ipairs(pending) do
        local index, name, batch = 1, nil, nil

        repeat
          name, batch = debug.getupvalue(on_result, index)
          index = index + 1
        until name == nil or name == "batch"
        assert.is_nil(batch.entries)
      end
    end)
  end)
end)
