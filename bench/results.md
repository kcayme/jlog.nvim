# jlog benchmark

Median of 5 runs after 1 warm-up; NVIM v0.12.6; jq-1.8.2.

## Parsing vs jq

Median ms for each contender to read the whole input into records.

| input | jlog load (ms) | jlog + field tree (ms) | vim.json.decode (ms) | jq (ms) |
|---|---:|---:|---:|---:|
| jsonl 10k | 30 | 63 | 11 | 54 |
| jsonl 100k | 407 | 1073 | 133 | 514 |
| jsonl 500k | 1993 | 5235 | 878 | 2517 |

- jlog load is what opening a file does: split lines, keep prefixes and continuation lines, and find each line's JSON with vim.json.decode.
- jlog + field tree adds jlog's own parse, which keeps key order and number literals as written, and unwraps double-encoded JSON; the plugin does this only for the lines it renders.
- vim.json.decode decodes each line and jq runs `jq -c .`; neither keeps key order or number literals.
- vim.json.decode and jq read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines.

## Workspace

What a user waits for in the plugin, in median ms; nothing in jq or `vim.json.decode` does the same work.

| input | open to screen (ms) | search (ms) | filter (ms) | group (ms) |
|---|---:|---:|---:|---:|
| jsonl 10k | 18 | 5 | 5 | 27 |
| jsonl 100k | 40 | 73 | 86 | 249 |
| jsonl 500k | 92 | 114 | 129 | 309 |

- Search is the bare term `licence`, filter is `status>=500`, group is by `request_id`.
- Search, filter and group run on the page a file opens on (page 1, the newest; at most paging.size plus overlap).
- Open to screen stops at the first screen, not the whole load.

## Cross-page count

Median ms from applying a filter on a paged file to its matches counted on every page, in the background.

| input | exact filter (ms) | longest stall (ms) | regex filter (ms) | longest stall (ms) | Lua heap (MB) | file (MB) |
|---|---:|---:|---:|---:|---:|---:|
| jsonl 500k | 952 | 54 | 5174 | 56 | 233 | 106 |
| array 500k | 5934 | 96 | 5774 | 98 | 163 | 105 |

- The exact filter is `status>=500`, matched on worker threads; the regex filter is the bare term `licence`, whose candidates the main thread confirms. Arrays scan on the main thread.
- Longest stall is the longest the main loop was busy in one go while counting, in any run, as a 1ms timer sees it; applying the filter to the page shown is in the Workspace table.
- Lua heap is after a full collection with the workspace open and the count done.
