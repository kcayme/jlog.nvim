local jobs = require("jlog.worker.jobs")
local json = require("jlog.parse.json")
local config = require("jlog.config")
local entry_model = require("jlog.parse.entry")
local facets = require("jlog.query.facets")
local filter = require("jlog.query.filter")
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
    assert.are.same({ "parse_lines", "count_entries", "match_lines", "match_elements" }, jobs.NAMES)
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

  describe("match_lines", function()
    local opts = { unwrap = config.defaults.unwrap, fields = config.defaults.fields }

    after_each(function()
      -- the job sets the options it is sent, as a thread would for itself
      config.setup()
    end)

    ---@param text string
    ---@param filters string[]
    ---@param extra table|nil
    local function scan(text, filters, extra)
      return run(
        "match_lines",
        vim.tbl_extend("force", {
          text = text,
          first_src = 1,
          first_byte = 1,
          filters = filters,
          opts = opts,
        }, extra or {})
      )
    end

    ---The source lines of the entries the full predicate matches, as the store would match them.
    local function expected_srcs(text, filters)
      local pred = filter.compile(filters)
      local srcs = {}
      local decoded

      for _, entry in ipairs(source.build(text, "jsonl")) do
        decoded = entry_model.decode(entry)
        if
          pred({
            raw = entry_model.key(entry),
            get = function(path)
              return entry_model.get(entry, decoded, path, config.options)
            end,
          })
        then
          srcs[#srcs + 1] = entry.src
        end
      end

      return srcs
    end

    ---A flat span list as `{ src, first, last }` tables.
    local function triples(list)
      local out = {}

      for at = 1, #list, 3 do
        out[#out + 1] = { src = list[at], first = list[at + 1], last = list[at + 2] }
      end

      return out
    end

    local function srcs_of(result)
      local srcs = {}

      for _, span in ipairs(vim.list_extend(triples(result.lead), triples(result.spans))) do
        srcs[#srcs + 1] = span.src
      end

      return srcs
    end

    it("should return the spans of matching entries with their continuation lines", function()
      local text = '{"a":1}\ncont1\n{"a":2}\n{"a":3}\ncont2'
      local result = scan(text, { "a>=2" }, { first_src = 10, first_byte = 101 })

      assert.are.same({
        { src = 12, first = 101 + 14, last = 101 + 20 },
        { src = 13, first = 101 + 22, last = 101 + #text - 1 },
      }, triples(result.spans))
      assert.are.equal(13, result.last_json_src)
      assert.are.same({}, result.lead)
      assert.is_true(result.exact)
    end)

    it("should report lines before the first JSON line as lead, each matched as a plain entry", function()
      local result = scan('plain one\n\nplain two\n{"a":1}', {})

      assert.are.same({ { src = 1, first = 1, last = 9 }, { src = 3, first = 12, last = 20 } }, triples(result.lead))
      assert.are.equal(20, result.lead_last)
      assert.are.same({ { src = 4, first = 22, last = 28 } }, triples(result.spans))
    end)

    it("should match what the full predicate matches, CRLF and continuation lines included", function()
      local text = table.concat(gen.jsonl_lines(400), "\r\n")

      for _, filters in ipairs({
        { "status>=500" },
        { "level=error" },
        { "status=500 OR status=502", "-path=/healthz" },
        { "latency_ms<10" },
        { "time>=2026-10-22T10:00:00.200Z" },
      }) do
        assert.are.same(expected_srcs(text, filters), srcs_of(scan(text, filters)), table.concat(filters, " / "))
      end
    end)

    it("should return every entry as a candidate when the filter has a regex term", function()
      local text = '{"msg":"boom"}\n{"msg":"calm"}'
      local result = scan(text, { "msg~boom" })

      assert.is_false(result.exact)
      assert.are.same({ 1, 2 }, srcs_of(result))
    end)

    it("should count a picked field's values under its other lines, skipping one with a regex", function()
      local text = '{"status":500,"msg":"a"}\n{"status":200,"msg":"b"}\n{"status":200,"msg":"c"}'

      assert.are.same({ ["500"] = 1, ["200"] = 2 }, scan(text, { "status=500" }).values.status.counts)
      assert.are.same({ ["200"] = 1 }, scan(text, { "status=500", "msg=b" }).values.status.counts)
      assert.is_nil(scan(text, { "status=500", "msg~b" }).values.status)
    end)

    it("should use the options it is sent, not the defaults", function()
      -- a bound without an offset is UTC with time_utc, so 05:00Z is before 10:00 whatever the local zone
      local text = '{"time":"2026-10-22T05:00:00Z"}\n{"time":"2026-10-22T11:00:00Z"}'
      local filters = { "time>=2026-10-22T10:00:00" }
      local result = scan(text, filters, { opts = vim.tbl_extend("force", opts, { time_utc = true }) })

      assert.are.same({ 2 }, srcs_of(result))
    end)
  end)
end)
