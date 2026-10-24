-- Benchmark: jlog parsing vs vim.json.decode and jq, plus workspace actions. Run with `make bench > bench/results.md`.
local gen = dofile("bench/gen.lua")
local source = require("jlog.parse.source")
local entry_model = require("jlog.parse.entry")
local config = require("jlog.config")
local workspace = require("jlog.workspace")

local RUNS = 5
local DATA_DIR = "bench/data"
-- every input kind runs at the same sizes as tests/perf.test.lua
local SIZES = { 10000, 100000, 500000 }
local opts = config.options
local has_jq = vim.fn.executable("jq") == 1
-- parsing: jlog against vim.json.decode and jq; workspace: what a user waits for in the plugin, no jq equivalent
local rows = { parsing = {}, workspace = {} }

local function write_file(path, text)
  local fd = assert(io.open(path, "wb"))

  fd:write(text)
  fd:close()
end

local function read_file(path)
  local fd = assert(io.open(path, "rb"))
  local text = fd:read("*a")

  fd:close()

  return text
end

---Generates an input once; the full file has prefixes and continuation lines, the pure one is bare JSON lines.
local function ensure(name, make)
  local path = DATA_DIR .. "/" .. name

  if not vim.uv.fs_stat(path) then
    write_file(path, make())
  end

  return path
end

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

---Median wall time in ms over RUNS runs after one warm-up; `fn` may return the ms it measured itself instead.
local function median(fn)
  local times = {}

  fn()
  for run = 1, RUNS do
    local start = now_ms()
    local measured = fn()

    times[run] = measured or now_ms() - start
  end
  table.sort(times)

  return times[math.ceil(RUNS / 2)]
end

local function ms_cell(ms)
  return string.format("%.0f", ms)
end

local function each_tree(entries)
  for _, entry in ipairs(entries) do
    entry_model.tree(entry, opts)
  end
end

---Median ms for jlog to parse `text` into entries with their field trees.
local function jlog_parse(text, format)
  return median(function()
    each_tree(source.build(text, format))
  end)
end

---Median ms for `jq args path`, or "-" when jq is not on PATH.
local function jq_cell(args, path)
  local cmd = "jq " .. args .. " " .. vim.fn.shellescape(path) .. " > /dev/null"

  if not has_jq then
    return "-"
  end

  return ms_cell(median(function()
    vim.system({ "sh", "-c", cmd }):wait()
  end))
end

---@param ws JLogWorkspace
local function wait_settled(ws)
  assert(vim.wait(120000, function()
    return not ws.loading and ws.indexing == nil and ws.rendered == ws.store.generation
  end, 1))
end

---Median ms from `action` to its apply rendered, after `reset` puts the workspace back each time.
local function apply_median(ws, reset, action)
  return median(function()
    local start

    reset()
    wait_settled(ws)
    collectgarbage("collect")
    start = now_ms()

    action()
    wait_settled(ws)

    return now_ms() - start
  end)
end

---Rows for the workspace: open to first screen, then a search and a group on the page it opens.
---One workspace row: median ms to open to the first screen, then to search, filter and group on that page.
local function workspace_rows(input, path)
  local ws
  local row = { input }

  local function add(ms)
    row[#row + 1] = ms_cell(ms)
  end

  add(median(function()
    local start, elapsed

    collectgarbage("collect")
    start = now_ms()

    ws = assert(workspace.open({ path = path }))
    elapsed = now_ms() - start
    wait_settled(ws)
    ws:close()

    return elapsed
  end))
  ws = assert(workspace.open({ path = path }))
  wait_settled(ws)
  add(apply_median(ws, function()
    ws:clear_filters()
  end, function()
    ws:add_filter("licence")
  end))
  add(apply_median(ws, function()
    ws:clear_filters()
  end, function()
    ws:add_filter("status>=500")
  end))
  add(apply_median(ws, function()
    ws:clear_filters()
    ws:set_group(nil)
  end, function()
    ws:set_group("request_id")
  end))
  ws:close()
  collectgarbage("collect")
  rows.workspace[#rows.workspace + 1] = row
end

local function bench_jsonl(size)
  local input = string.format("jsonl %dk", size / 1000)
  local path = ensure("app-" .. size .. ".jsonl", function()
    return table.concat(gen.jsonl_lines(size), "\n") .. "\n"
  end)
  local pure_path = ensure("pure-" .. size .. ".jsonl", function()
    return table.concat(gen.jsonl_lines(size, true), "\n") .. "\n"
  end)
  local pure_lines = vim.split(read_file(pure_path), "\n", { plain = true, trimempty = true })
  local jlog_ms = jlog_parse(read_file(path), "jsonl")

  workspace_rows(input, path)

  rows.parsing[#rows.parsing + 1] = {
    input,
    ms_cell(jlog_ms),
    ms_cell(median(function()
      for _, line in ipairs(pure_lines) do
        vim.json.decode(line)
      end
    end)),
    jq_cell("-c .", pure_path),
  }
end

local function bench_array(size)
  local input = string.format("array %dk", size / 1000)
  local path = ensure("array-" .. size .. ".json", function()
    return gen.array_text(size)
  end)
  local text = read_file(path)
  local jlog_ms = jlog_parse(text, "array")

  workspace_rows(input, path)

  rows.parsing[#rows.parsing + 1] = {
    input,
    ms_cell(jlog_ms),
    ms_cell(median(function()
      vim.json.decode(text)
    end)),
    jq_cell("-c '.[]'", path),
  }
end

vim.fn.mkdir(DATA_DIR, "p")
require("jlog").setup()
opts = config.options

for _, size in ipairs(SIZES) do
  bench_jsonl(size)
end
for _, size in ipairs(SIZES) do
  bench_array(size)
end

---Append a Markdown table of `list` to `out`, with its header and alignment rows.
local function table_lines(out, header, align, list)
  out[#out + 1] = header
  out[#out + 1] = align
  for _, row in ipairs(list) do
    out[#out + 1] = "| " .. table.concat(row, " | ") .. " |"
  end
  out[#out + 1] = ""
end

local out = {
  "# jlog benchmark",
  "",
  string.format(
    "Median of %d runs after 1 warm-up; %s; %s.",
    RUNS,
    vim.fn.system("nvim --version"):match("NVIM v[^\n]+"),
    has_jq and vim.fn.system("jq --version"):gsub("\n", "") or "jq not found (jq column skipped)"
  ),
  "",
  "## Parsing vs jq",
  "",
  "Median ms for each contender to read the whole input into records.",
  "",
}

table_lines(out, "| input | jlog | vim.json.decode | jq |", "|---|---:|---:|---:|", rows.parsing)
out[#out + 1] =
  "jlog builds its entries and each entry's field tree; it keeps key order and number literals as written."
out[#out + 1] =
  "vim.json.decode decodes each line (jsonl) or the whole array; jq runs `jq -c .` (jsonl) or `jq -c '.[]'` (array)."
out[#out + 1] = "jq does not build jlog's entry model or continuation lines."
out[#out + 1] =
  "For jsonl, vim.json.decode and jq read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines."
if not has_jq then
  out[#out + 1] = "Notice: jq is not on PATH, the jq column was skipped."
end
out[#out + 1] = ""
out[#out + 1] = "## Workspace"
out[#out + 1] = ""
out[#out + 1] =
  "What a user waits for in the plugin, in median ms; nothing in jq or `vim.json.decode` does the same work."
out[#out + 1] = ""
table_lines(out, "| input | open to screen | search | filter | group |", "|---|---:|---:|---:|---:|", rows.workspace)
out[#out + 1] = "Search is the bare term `licence`, filter is `status>=500`, group is by `request_id`."
out[#out + 1] =
  "Search, filter and group run on the page a file opens on (page 1, the newest; at most paging.size plus overlap)."
out[#out + 1] = "Open to screen stops at the first screen, not the whole load."

io.write(table.concat(out, "\n"), "\n")
