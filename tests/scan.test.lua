local config = require("jlog.config")
local entry_model = require("jlog.parse.entry")
local filter = require("jlog.query.filter")
local pages = require("jlog.parse.pages")
local scan = require("jlog.query.scan")
local source = require("jlog.parse.source")
local workers = require("jlog.worker")
local gen = dofile("bench/gen.lua")

local PAGING = { size = 120, overlap = 15 }

---Plain lines before any JSON, continuation lines, blank lines and CRLF, then generated lines with stack traces.
local function edge_text()
  local lines = {
    "booting service v1",
    "",
    "second plain line",
    '{"level":"INFO","msg":"start","status":200}',
    "  at frame one",
    "",
    "  at frame two",
    '{"level":"ERROR","msg":"panic","status":500}\r',
    "  caused by: timeout\r",
  }

  vim.list_extend(lines, gen.jsonl_lines(600))

  return table.concat(lines, "\n")
end

---@param text string
---@param format JLogFormat
---@param from_end boolean|nil page 1 holds the end of the text
---@return JLogPageIndex
local function index_of(text, format, from_end)
  local index = pages.new(text, format, PAGING, from_end == true)

  while not index:scan(vim.uv.hrtime() + 1e9) do
  end

  return index
end

---The sources of the entries the full predicate matches over the unpaged source, as the engine would match them.
local function expected_srcs(text, format, filters)
  local pred = filter.compile(filters)
  local srcs = {}
  local decoded

  for _, entry in ipairs(source.build(text, format)) do
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

---Run a scan to its end and return it.
local function run(index, format, filters)
  local result

  scan.run(index, format, filters, config.options, function() end, function(done)
    result = done
  end)
  assert.is_true(vim.wait(20000, function()
    return result ~= nil
  end, 5))

  return result
end

local function srcs_of(result)
  return vim.tbl_map(function(match)
    return match.src
  end, result.matches)
end

describe("scan", function()
  local chunk_bytes = scan.chunk_bytes
  local main_chunk_bytes = scan.main_chunk_bytes
  local chunk_elements = pages.chunk_elements
  local run_job = workers.run

  after_each(function()
    scan.chunk_bytes = chunk_bytes
    scan.main_chunk_bytes = main_chunk_bytes
    pages.chunk_elements = chunk_elements
    workers.disabled = nil
    workers.run = run_job
  end)

  local FILTERS = {
    { "status>=500" },
    { "level=error" },
    { "status=500 OR status=502", "-path=/healthz" },
    { "-status=200" },
    { "frame" },
    { "msg~^request", "status=404" },
    { "timeout" },
  }

  for _, on_workers in ipairs({ true, false }) do
    it("should match what the engine matches over the unpaged source, workers " .. tostring(on_workers), function()
      local text = edge_text()
      local index = index_of(text, "jsonl")

      -- small chunks put chunk edges inside entries and their continuation lines
      scan.chunk_bytes, scan.main_chunk_bytes = 700, 300
      workers.disabled = not on_workers or nil
      for _, filters in ipairs(FILTERS) do
        assert.are.same(
          expected_srcs(text, "jsonl", filters),
          srcs_of(run(index, "jsonl", filters)),
          table.concat(filters, " / ")
        )
      end
    end)
  end

  for _, on_workers in ipairs({ true, false }) do
    it(
      "should join continuation lines cut into the next chunk to their entry, workers " .. tostring(on_workers),
      function()
        local text = '{"msg":"a"}\n  at frame x\n\n  at frame y\n{"msg":"b"}\nplain after b'
        local result

        -- one-byte chunks cut at every line
        scan.chunk_bytes, scan.main_chunk_bytes = 1, 1
        workers.disabled = not on_workers or nil
        result = run(index_of(text, "jsonl"), "jsonl", { "frame" })

        assert.are.same({ 1 }, srcs_of(result))
        assert.are.equal(
          '{"msg":"a"}\n  at frame x\n\n  at frame y',
          text:sub(result.matches[1].first, result.matches[1].last)
        )
        assert.are.same({ 5 }, srcs_of(run(index_of(text, "jsonl"), "jsonl", { "-frame" })))
      end
    )
  end

  it("should give each match the bytes of its lines, continuation lines included", function()
    local text = edge_text()
    local result = run(index_of(text, "jsonl"), "jsonl", { "status=500", "msg=panic" })

    assert.are.equal(8, result.matches[1].src)
    assert.are.equal(
      '{"level":"ERROR","msg":"panic","status":500}\r\n  caused by: timeout\r',
      text:sub(result.matches[1].first, result.matches[1].last)
    )
  end)

  it("should count each page's own matches once, overlap left out", function()
    local text = edge_text()
    local index = index_of(text, "jsonl")
    local result = run(index, "jsonl", { "status>=500" })
    local counts = scan.page_counts(result, index)
    local total = 0

    assert.is_true(index:count() > 2)
    for _, count in ipairs(counts) do
      total = total + count
    end
    assert.are.equal(#result.matches, total)
  end)

  it("should never call on_done once cancelled", function()
    local text = edge_text()
    local called = false
    local running = scan.run(
      index_of(text, "jsonl"),
      "jsonl",
      { "status>=500" },
      config.options,
      function() end,
      function()
        called = true
      end
    )

    scan.cancel(running)
    vim.wait(500)
    assert.is_false(called)
  end)

  it("should match on the main thread when a worker job fails", function()
    local text = edge_text()

    scan.chunk_bytes = 700
    workers.run = function(_, _, on_result)
      vim.defer_fn(function()
        on_result("boom", nil)
      end, 0)
    end
    assert.are.same(
      expected_srcs(text, "jsonl", { "status>=500" }),
      srcs_of(run(index_of(text, "jsonl"), "jsonl", { "status>=500" }))
    )
  end)

  describe("arrays", function()
    local array_text = "[\n" .. table.concat(gen.jsonl_lines(500, true), ",\n") .. "\n]"
    local sources = {
      { format = "array", text = array_text },
      { format = "loki", text = gen.loki_text(500) },
    }

    before_each(function()
      -- several chunks per page
      pages.chunk_elements = 40
    end)

    for _, case in ipairs(sources) do
      for _, from_end in ipairs({ false, true }) do
        it(
          "should match "
            .. case.format
            .. " chunks on worker threads as the engine matches, from_end "
            .. tostring(from_end),
          function()
            local index = index_of(case.text, case.format, from_end)
            local jobs, failed = 0, 0

            workers.run = function(name, payload, on_result)
              jobs = jobs + 1
              run_job(name, payload, function(err, result)
                failed = failed + (err and 1 or 0)
                on_result(err, result)
              end)
            end
            assert.is_true(index:count() > 2)
            for _, filters in ipairs(FILTERS) do
              jobs = 0
              assert.are.same(
                expected_srcs(case.text, case.format, filters),
                srcs_of(run(index, case.format, filters)),
                table.concat(filters, " / ")
              )
              -- every chunk went to a worker, none fell back to the main thread
              assert.are.equal(#index.chunks, jobs)
            end
            assert.are.equal(0, failed)
          end
        )
      end

      it("should match " .. case.format .. " elements on the main thread without workers", function()
        local index = index_of(case.text, case.format)

        workers.disabled = true
        for _, filters in ipairs(FILTERS) do
          assert.are.same(
            expected_srcs(case.text, case.format, filters),
            srcs_of(run(index, case.format, filters)),
            table.concat(filters, " / ")
          )
        end
      end)
    end

    it("should go on from the failed chunk on the main thread, without counting a chunk twice", function()
      local index = index_of(array_text, "array")
      local jobs = 0
      local result

      workers.run = function(name, payload, on_result)
        jobs = jobs + 1
        if jobs == 2 then
          vim.defer_fn(function()
            on_result("boom", nil)
          end, 0)

          return
        end
        run_job(name, payload, on_result)
      end
      result = run(index, "array", { "status=500 OR status=502" })
      assert.are.same(expected_srcs(array_text, "array", { "status=500 OR status=502" }), srcs_of(result))
      -- a picked field with no other lines counts every element once
      assert.are.equal(500, result.facets.fields.status.present)
    end)

    it("should stop where a broken array breaks, keeping the matches before it and the reason", function()
      local lines = gen.jsonl_lines(300, true)
      local text, expected, result

      lines[150] = '{"status":500, broken'
      text = "[\n" .. table.concat(lines, ",\n") .. "\n]"
      expected =
        expected_srcs("[\n" .. table.concat(vim.list_slice(lines, 1, 149), ",\n") .. "\n]", "array", { "status>=500" })
      result = run(index_of(text, "array"), "array", { "status>=500" })
      assert.are.same(expected, srcs_of(result))
      assert.is_truthy(result.err)
    end)
  end)

  describe("entries", function()
    ---The entries a scan's matches read back into, once done.
    local function entries_of(result)
      local entries

      scan.entries(result, function(read)
        entries = read
      end)
      assert.is_true(vim.wait(20000, function()
        return entries ~= nil
      end, 5))

      return entries
    end

    ---The loaded source's entries the full predicate matches, as raw text, continuation lines and source.
    local function expected_entries(text, format, filters)
      local srcs = {}
      local out = {}

      for _, src in ipairs(expected_srcs(text, format, filters)) do
        srcs[src] = true
      end
      for _, entry in ipairs(source.build(text, format)) do
        if srcs[entry.src] then
          out[#out + 1] = { src = entry.src, raw = entry.raw, cont = entry.cont, labels = entry.labels }
        end
      end

      return out
    end

    local function shape(entries)
      return vim.tbl_map(function(entry)
        return { src = entry.src, raw = entry.raw, cont = entry.cont, labels = entry.labels }
      end, entries)
    end

    it("should read the matched jsonl entries with their continuation lines, in file order", function()
      local text = edge_text()

      scan.chunk_bytes = 700
      for _, filters in ipairs({ { "status>=500" }, { "frame" }, { "-status=200" } }) do
        assert.are.same(
          expected_entries(text, "jsonl", filters),
          shape(entries_of(run(index_of(text, "jsonl"), "jsonl", filters))),
          table.concat(filters, " / ")
        )
      end
    end)

    for _, from_end in ipairs({ false, true }) do
      it("should read matched array elements once each, in file order, from_end " .. tostring(from_end), function()
        local text = "[\n" .. table.concat(gen.jsonl_lines(500, true), ",\n") .. "\n]"

        assert.are.same(
          expected_srcs(text, "array", { "status>=500" }),
          vim.tbl_map(function(entry)
            return entry.src
          end, entries_of(run(index_of(text, "array", from_end), "array", { "status>=500" })))
        )
      end)
    end

    it("should read matched loki elements with their labels, in file order", function()
      local text = gen.loki_text(500)
      local filters = { "status>=500" }

      assert.are.same(
        expected_entries(text, "loki", filters),
        shape(entries_of(run(index_of(text, "loki"), "loki", filters)))
      )
    end)

    it("should never call on_done once cancelled", function()
      local text = edge_text()
      local called = false
      local cancel = scan.entries(run(index_of(text, "jsonl"), "jsonl", { "status>=500" }), function()
        called = true
      end)

      cancel()
      vim.wait(300)
      assert.is_false(called)
    end)
  end)
end)
