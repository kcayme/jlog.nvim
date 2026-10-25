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
local rows = { parsing = {}, workspace = {}, scan = {}, all = {} }

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

---Median ms for jlog to load `text` into entries, as opening a file does.
local function jlog_load(text, format)
  return median(function()
    source.build(text, format)
  end)
end

---Median ms for jlog to load `text` and build every entry's field tree, which the plugin does only for rendered lines.
local function jlog_tree(text, format)
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

---Median ms from applying `filter` to every page's matches counted, and the longest stall the scan caused in any run.
---@param ws JLogWorkspace
---@param filter string
---@return number ms
---@return number stall_ms
local function scan_median(ws, filter)
  local stall = 0
  local ms = median(function()
    local timer = vim.uv.new_timer()
    local last = now_ms()
    local start

    ws:clear_filters()
    wait_settled(ws)
    collectgarbage("collect")
    start = now_ms()
    ws:add_filter(filter)
    -- the scan starts once the page has rendered; a 1ms timer that fires late measures how long it kept the loop busy
    wait_settled(ws)
    last = now_ms()
    timer:start(1, 1, function()
      stall = math.max(stall, now_ms() - last)
      last = now_ms()
    end)
    assert(vim.wait(120000, function()
      return ws.scan ~= nil and ws.scan.done
    end, 1))
    timer:stop()
    timer:close()

    return now_ms() - start
  end)

  return ms, stall
end

---One row of the cross-page count: an exact filter and a regex-only one, counted on every page of a paged file.
local function scan_rows(input, path)
  local ws = assert(workspace.open({ path = path }))
  local exact_ms, exact_stall, regex_ms, regex_stall, heap

  wait_settled(ws)
  exact_ms, exact_stall = scan_median(ws, "status>=500")
  regex_ms, regex_stall = scan_median(ws, "licence")
  collectgarbage("collect")
  heap = collectgarbage("count") / 1024
  rows.scan[#rows.scan + 1] = {
    input,
    ms_cell(exact_ms),
    ms_cell(exact_stall),
    ms_cell(regex_ms),
    ms_cell(regex_stall),
    string.format("%.0f", heap),
    string.format("%.0f", vim.uv.fs_stat(path).size / 1024 / 1024),
  }
  ws:close()
  collectgarbage("collect")
end

---One combined-view row: median ms from `toggle_scope` to every page's `filter` matches shown, stall and heap.
local function all_rows(input, path, filter)
  local ws = assert(workspace.open({ path = path }))
  local stall = 0
  local ms, heap

  wait_settled(ws)
  ws:add_filter(filter)
  assert(vim.wait(120000, function()
    return ws.scan ~= nil and ws.scan.done and not ws.loading and ws.rendered == ws.store.generation
  end, 1))
  ms = median(function()
    local timer = vim.uv.new_timer()
    local last = now_ms()
    local start

    if ws.scope == "all" then
      ws:toggle_scope()
      wait_settled(ws)
    end
    collectgarbage("collect")
    start, last = now_ms(), now_ms()
    timer:start(1, 1, function()
      stall = math.max(stall, now_ms() - last)
      last = now_ms()
    end)
    ws:toggle_scope()
    assert(vim.wait(120000, function()
      return ws.scope == "all" and not ws.loading and ws.rendered == ws.store.generation
    end, 1))
    timer:stop()
    timer:close()

    return now_ms() - start
  end)
  collectgarbage("collect")
  heap = collectgarbage("count") / 1024
  rows.all[#rows.all + 1] = {
    input,
    tostring(#ws.entries),
    ms_cell(ms),
    ms_cell(stall),
    string.format("%.0f", heap),
    string.format("%.0f", vim.uv.fs_stat(path).size / 1024 / 1024),
  }
  ws:close()
  collectgarbage("collect")
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
  local text = read_file(path)
  local load_ms, tree_ms = jlog_load(text, "jsonl"), jlog_tree(text, "jsonl")

  workspace_rows(input, path)

  rows.parsing[#rows.parsing + 1] = {
    input,
    ms_cell(load_ms),
    ms_cell(tree_ms),
    ms_cell(median(function()
      for _, line in ipairs(pure_lines) do
        vim.json.decode(line)
      end
    end)),
    jq_cell("-c .", pure_path),
  }
end

vim.fn.mkdir(DATA_DIR, "p")
require("jlog").setup()
opts = config.options

for _, size in ipairs(SIZES) do
  bench_jsonl(size)
end
-- after the parsing rows, whose texts and line lists would otherwise stay live and slow every collection
collectgarbage("collect")
for _, size in ipairs(SIZES) do
  if size > config.options.paging.size then
    scan_rows(string.format("jsonl %dk", size / 1000), DATA_DIR .. "/app-" .. size .. ".jsonl")
    -- one entry in five is an error: 100k at 500k lines, the most the combined view takes
    all_rows(string.format("jsonl %dk", size / 1000), DATA_DIR .. "/app-" .. size .. ".jsonl", "level=ERROR")
  end
end
-- arrays scan on the main thread, page by page
local array_path = ensure("array-500000.json", function()
  return "[\n" .. table.concat(gen.jsonl_lines(500000, true), ",\n") .. "\n]\n"
end)
scan_rows("array 500k", array_path)
all_rows("array 500k", array_path, "level=ERROR")

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

table_lines(
  out,
  "| input | jlog load (ms) | jlog + field tree (ms) | vim.json.decode (ms) | jq (ms) |",
  "|---|---:|---:|---:|---:|",
  rows.parsing
)
out[#out + 1] = "- jlog load is what opening a file does: split lines, keep prefixes and continuation lines, and find each "
  .. "line's JSON with vim.json.decode."
out[#out + 1] = "- jlog + field tree adds jlog's own parse, which keeps key order and number literals as written, and unwraps "
  .. "double-encoded JSON; the plugin does this only for the lines it renders."
out[#out + 1] = "- vim.json.decode decodes each line and jq runs `jq -c .`; neither keeps key order or number literals."
out[#out + 1] =
  "- vim.json.decode and jq read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines."
if not has_jq then
  out[#out + 1] = "- Notice: jq is not on PATH, the jq column was skipped."
end
out[#out + 1] = ""
out[#out + 1] = "## Workspace"
out[#out + 1] = ""
out[#out + 1] =
  "What a user waits for in the plugin, in median ms; nothing in jq or `vim.json.decode` does the same work."
out[#out + 1] = ""
table_lines(
  out,
  "| input | open to screen (ms) | search (ms) | filter (ms) | group (ms) |",
  "|---|---:|---:|---:|---:|",
  rows.workspace
)
out[#out + 1] = "- Search is the bare term `licence`, filter is `status>=500`, group is by `request_id`."
out[#out + 1] =
  "- Search, filter and group run on the page a file opens on (page 1, the newest; at most paging.size plus overlap)."
out[#out + 1] = "- Open to screen stops at the first screen, not the whole load."

out[#out + 1] = ""
out[#out + 1] = "## Cross-page count"
out[#out + 1] = ""
out[#out + 1] =
  "Median ms from applying a filter on a paged file to its matches counted on every page, in the background."
out[#out + 1] = ""
table_lines(
  out,
  "| input | exact filter (ms) | longest stall (ms) | regex filter (ms) | longest stall (ms) | Lua heap (MB) | file (MB) |",
  "|---|---:|---:|---:|---:|---:|---:|",
  rows.scan
)
out[#out + 1] = "- The exact filter is `status>=500`, matched on worker threads; the regex filter is the bare term `licence`, "
  .. "whose candidates the main thread confirms. Arrays scan on the main thread."
out[#out + 1] = "- Longest stall is the longest the main loop was busy in one go while counting, in any run, as a 1ms timer "
  .. "sees it; applying the filter to the page shown is in the Workspace table."
out[#out + 1] = "- Lua heap is after a full collection with the workspace open and the count done."
out[#out + 1] = ""
out[#out + 1] = "## All pages in one view"
out[#out + 1] = ""
out[#out + 1] = "Median ms from `A` to every page's matches of `level=ERROR` shown in one view, once they are counted."
out[#out + 1] = ""
table_lines(
  out,
  "| input | entries shown | to shown (ms) | longest stall (ms) | Lua heap (MB) | file (MB) |",
  "|---|---:|---:|---:|---:|---:|",
  rows.all
)
out[#out + 1] =
  "- 100k entries is paging.size, the most the view takes; longest stall is over every run, as a 1ms timer sees it."

io.write(table.concat(out, "\n"), "\n")
