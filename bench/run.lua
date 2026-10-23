-- Benchmark: jlog parse/render vs vim.json.decode and jq. Dev-only. Run with `make bench > bench/results.md`.
local gen = dofile("bench/gen.lua")
local source = require("jlog.parse.source")
local entry_model = require("jlog.parse.entry")
local render = require("jlog.ui.render")
local config = require("jlog.config")

local RUNS = 5
local DATA_DIR = "bench/data"
-- every input kind runs at the same sizes as tests/perf.test.lua
local SIZES = { 10000, 100000, 500000 }
local opts = config.options
local has_jq = vim.fn.executable("jq") == 1
local rows = {}

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

---Median wall time in ms over RUNS runs after one warm-up.
local function median(fn)
  local times = {}

  fn()
  for run = 1, RUNS do
    local start = now_ms()

    fn()
    times[run] = now_ms() - start
  end
  table.sort(times)

  return times[math.ceil(RUNS / 2)]
end

local function add_row(input, contender, count, ms, memory_mb)
  rows[#rows + 1] = {
    input,
    contender,
    string.format("%.0f", ms),
    string.format("%.0f", count / (ms / 1000)),
    memory_mb and string.format("%.0f", memory_mb) or "-",
  }
end

local function each_tree(entries)
  for _, entry in ipairs(entries) do
    entry_model.tree(entry, opts)
  end
end

local function jlog_rows(input, text, format)
  local entries
  local baseline, memory_mb

  collectgarbage("collect")
  baseline = collectgarbage("count")
  entries = source.build(text, format)
  each_tree(entries)
  collectgarbage("collect")
  memory_mb = (collectgarbage("count") - baseline) / 1024
  add_row(
    input,
    "jlog parse only",
    #entries,
    median(function()
      each_tree(source.build(text, format))
    end),
    memory_mb
  )
  add_row(
    input,
    "jlog parse + compact render",
    #entries,
    median(function()
      for _, entry in ipairs(source.build(text, format)) do
        render.compact(entry, opts, true)
      end
    end)
  )
  add_row(
    input,
    "jlog parse + expanded render",
    #entries,
    median(function()
      for _, entry in ipairs(source.build(text, format)) do
        render.expanded(entry, opts)
      end
    end)
  )

  return #entries
end

local function jq_row(input, contender, count, args, path)
  local cmd = "jq " .. args .. " " .. vim.fn.shellescape(path) .. " > /dev/null"

  add_row(
    input,
    contender,
    count,
    median(function()
      vim.system({ "sh", "-c", cmd }):wait()
    end)
  )
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
  local count = jlog_rows(input, read_file(path), "jsonl")

  add_row(
    input,
    "vim.json.decode per line (pure lines)",
    #pure_lines,
    median(function()
      for _, line in ipairs(pure_lines) do
        vim.json.decode(line)
      end
    end)
  )
  if has_jq then
    jq_row(input, "jq -c . (pure lines)", #pure_lines, "-c .", pure_path)
    jq_row(input, "jq . (pure lines)", #pure_lines, ".", pure_path)
  end

  return count
end

local function bench_loki(size)
  local input = string.format("loki %dk", size / 1000)
  local path = ensure("loki-" .. size .. ".json", function()
    return gen.loki_text(size)
  end)
  local text = read_file(path)
  local count = jlog_rows(input, text, "loki")

  add_row(
    input,
    "vim.json.decode array + line",
    count,
    median(function()
      for _, item in ipairs(vim.json.decode(text)) do
        pcall(vim.json.decode, item.line)
      end
    end)
  )
  if has_jq then
    jq_row(input, "jq -c '.[] | .line | fromjson? // .'", count, "-c '.[] | .line | fromjson? // .'", path)
  end
end

vim.fn.mkdir(DATA_DIR, "p")
require("jlog").setup()
opts = config.options

for _, size in ipairs(SIZES) do
  bench_jsonl(size)
end
for _, size in ipairs(SIZES) do
  bench_loki(size)
end

local out = {
  "# jlog benchmark",
  "",
  string.format(
    "Median of %d runs after 1 warm-up; %s; %s.",
    RUNS,
    vim.fn.system("nvim --version"):match("NVIM v[^\n]+"),
    has_jq and vim.fn.system("jq --version"):gsub("\n", "") or "jq not found (jq rows skipped)"
  ),
  "",
  "| input | contender | median ms | entries/s | Lua MB after parse |",
  "|---|---|---:|---:|---:|",
}

for _, row in ipairs(rows) do
  -- a `|` inside a cell (the jq loki filter) would split the Markdown table
  out[#out + 1] = "| "
    .. table.concat(
      vim.tbl_map(function(cell)
        return (tostring(cell):gsub("|", "\\|"))
      end, row),
      " | "
    )
    .. " |"
end
out[#out + 1] = ""
out[#out + 1] = "jq does not build jlog's entry model or continuation lines."
out[#out + 1] =
  "jq and `vim.json.decode` rows read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines."
out[#out + 1] =
  "Lua MB after parse is approximate: LuaJIT interns strings, so entry strings that equal the input text add nothing."
if not has_jq then
  out[#out + 1] = "Notice: jq is not on PATH, jq rows were skipped."
end

io.write(table.concat(out, "\n"), "\n")
