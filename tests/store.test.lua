local config = require("jlog.config")
local entry_model = require("jlog.parse.entry")
local filter = require("jlog.query.filter")
local source = require("jlog.parse.source")
local facets = require("jlog.query.facets")
local store_mod = require("jlog.store")
local workers = require("jlog.workers")

local TEXT = table.concat({
  '{"status":200,"request_id":"a"}',
  '{"status":500,"request_id":"a"}',
  '{"status":500,"request_id":"b"}',
}, "\n")

describe("store", function()
  local timing = vim.deepcopy(store_mod.timing)
  local notify = vim.notify
  local store

  local function status_500()
    return (filter.compile({ "status=500" }))
  end

  before_each(function()
    vim.notify = function() end
    store = store_mod.new({
      entries = source.build(TEXT, "jsonl"),
      opts = config.setup(),
      state = { filters = {}, reverse = false, expanded = {}, mode = "compact" },
      stored_newest_first = false,
    })
  end)

  after_each(function()
    vim.notify = notify
    store_mod.timing = vim.deepcopy(timing)
  end)

  it("should report the matching entries in order", function()
    local items, shown

    store:query(status_500(), nil, function(result, count)
      items, shown = result, count
    end)

    assert.are.same({ { kind = "entry", idx = 2 }, { kind = "entry", idx = 3 } }, items)
    assert.are.equal(2, shown)
  end)

  it("should group by a field", function()
    local items

    store:query(status_500(), "request_id", function(result)
      items = result
    end)

    assert.are.equal("header", items[1].kind)
    assert.are.equal("a", items[1].group.label)
  end)

  it("should drop a superseded query's result", function()
    local first, second = false, false

    -- more entries than one scan batch, so the first query spans ticks
    store.source.entries = source.build(string.rep('{"status":500}\n', 1200), "jsonl")
    store_mod.timing.tick_ns = 0
    store:query(status_500(), nil, function()
      first = true
    end)
    store:query(status_500(), nil, function()
      second = true
    end)
    assert.is_true(store.running)

    assert.is_true(vim.wait(1000, function()
      return second
    end, 10))
    assert.is_false(first)
    assert.is_false(store.running)
  end)

  it("should not stay running when the filter raises", function()
    local ok = pcall(store.query, store, function()
      error("boom")
    end, nil, function() end)

    assert.is_false(ok)
    assert.is_false(store.running)
  end)

  it("should count the matched entries", function()
    local counter

    store:query(status_500(), nil, function() end)
    store:count(function(result)
      counter = result
    end)

    assert.is_true(vim.wait(1000, function()
      return counter ~= nil
    end, 10))
    assert.are.equal(2, counter.fields.status.counts["500"])
    assert.are.equal(counter, store.counter)
  end)

  it("should add appended matches to a finished count", function()
    local counter, entry

    store:query(status_500(), nil, function() end)
    store:count(function(result)
      counter = result
    end)
    vim.wait(1000, function()
      return counter ~= nil
    end, 10)
    entry = source.build('{"status":500,"request_id":"c"}', "jsonl")[1]
    store:count_appended(4, entry, entry_model.decode(entry))

    assert.are.equal(3, counter.fields.status.counts["500"])
  end)

  describe("threaded counts", function()
    local run = workers.run
    local batch_bytes = store_mod.count_batch_bytes

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
      store.source.entries = source.build(build_lines(), "jsonl")
      store:query(function()
        return true
      end, nil, function() end)
      store:count(function(result)
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
      store_mod.count_batch_bytes = batch_bytes
    end)

    it("should count a large match on workers with the same uncapped counts", function()
      local jobs = 0
      local expected, actual

      store_mod.count_batch_bytes = 4096
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

      store_mod.count_batch_bytes = 4096
      store.source.entries = source.build(build_lines(), "jsonl")
      store:query(function()
        return true
      end, nil, function() end)
      store:count(function()
        done = true
      end)
      store:query(status_500(), nil, function() end)

      assert.is_false(vim.wait(1000, function()
        return done
      end, 10))
    end)

    it("should count a failed batch on the main thread", function()
      local calls = 0
      local expected, actual

      store_mod.count_batch_bytes = 4096
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
  end)
end)
