local jobs = require("jlog.worker.jobs")
local json = require("jlog.parse.json")
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local source = require("jlog.parse.source")
local gen = dofile("bench/gen.lua")

local function run(name, payload)
  return vim.mpack.decode(jobs[name](vim.mpack.encode(payload)))
end

local function from_fields(fields)
  local counter = facets.counter()

  facets.merge(counter, fields)

  return counter
end

describe("jobs", function()
  it("should list its job names", function()
    assert.are.same({ "parse_lines", "count_entries" }, jobs.NAMES)
  end)

  it("should find the same JSON lines as a main-thread load", function()
    local fixture = table.concat(vim.fn.readfile("tests/fixtures/app.jsonl", "b"), "\n")
    local text = fixture .. "\n" .. table.concat(gen.nested_lines(300), "\n")
    local lines = vim.split(text, "\n", { plain = true })
    local result = run("parse_lines", { text = text })
    local expected = {}

    for index, line in ipairs(lines) do
      expected[index] = line:find("%S") and json.object_at((line:gsub("\r$", ""))) or 0
    end

    assert.are.same(expected, result.positions)
  end)

  it("should strip a trailing carriage return before finding JSON", function()
    assert.are.same({ 1 }, run("parse_lines", { text = '{"msg":"a"}\r' }).positions)
  end)

  it("should give a blank line position 0", function()
    assert.are.same({ 1, 0, 0 }, run("parse_lines", { text = '{"a":1}\n\nplain' }).positions)
  end)

  it("should count fields like the load does", function()
    local lines = gen.nested_lines(300, true)
    local result = run("parse_lines", { text = table.concat(lines, "\n") })
    local expected = facets.counter()

    for _, entry in ipairs(source.build(table.concat(lines, "\n"), "jsonl")) do
      facets.add(expected, entry_model.flatten(entry, entry_model.decode(entry)))
    end

    assert.are.same(facets.result(expected, 50), facets.result(from_fields(result.fields), 50))
  end)

  it("should count entries with labels like Store.count does", function()
    local entries = {
      { body = '{"msg":"a"}', json_at = 1, labels = { app = "a" } },
      { body = '{"msg":"b"}', json_at = 1, labels = { app = "a" } },
    }
    local result = run("count_entries", { entries = entries })

    assert.are.equal(2, result.fields["labels.app"].counts["a"])
    assert.are.equal(1, result.fields.msg.counts["a"])
  end)
end)
