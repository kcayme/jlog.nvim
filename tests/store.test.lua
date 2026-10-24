local config = require("jlog.config")
local entry_model = require("jlog.parse.entry")
local filter = require("jlog.query.filter")
local source = require("jlog.parse.source")
local store_mod = require("jlog.store")

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

    assert.is_true(vim.wait(1000, function()
      return second
    end, 10))
    assert.is_false(first)
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
end)
