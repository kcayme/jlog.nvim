# jlog benchmark

Median of 5 runs after 1 warm-up; NVIM v0.12.6; jq-1.8.2.

## Parsing vs jq

Median ms for each contender to read the whole input into records.

| input | jlog load (ms) | jlog + field tree (ms) | vim.json.decode (ms) | jq (ms) |
|---|---:|---:|---:|---:|
| jsonl 10k | 29 | 60 | 11 | 53 |
| jsonl 100k | 401 | 1030 | 130 | 497 |
| jsonl 500k | 1941 | 5207 | 860 | 2516 |

- jlog load is what opening a file does: split lines, keep prefixes and continuation lines, and find each line's JSON with vim.json.decode.
- jlog + field tree adds jlog's own parse, which keeps key order and number literals as written, and unwraps double-encoded JSON; the plugin does this only for the lines it renders.
- vim.json.decode decodes each line and jq runs `jq -c .`; neither keeps key order or number literals.
- vim.json.decode and jq read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines.

## Workspace

What a user waits for in the plugin, in median ms; nothing in jq or `vim.json.decode` does the same work.

| input | open to screen (ms) | search (ms) | filter (ms) | group (ms) |
|---|---:|---:|---:|---:|
| jsonl 10k | 18 | 4 | 5 | 27 |
| jsonl 100k | 37 | 75 | 88 | 236 |
| jsonl 500k | 90 | 109 | 117 | 267 |

- Search is the bare term `licence`, filter is `status>=500`, group is by `request_id`.
- Search, filter and group run on the page a file opens on (page 1, the newest; at most paging.size plus overlap).
- Open to screen stops at the first screen, not the whole load.

## All pages in one view

Median ms from a filter to every page's matches shown in one view, and from a group to it grouped over them.

| input | entries shown | filter (ms) | longest stall (ms) | group (ms) | longest stall (ms) | Lua heap (MB) | file (MB) |
|---|---:|---:|---:|---:|---:|---:|---:|
| jsonl 500k | 100000 | 2106 | 93 | 669 | 44 | 220 | 106 |
| array 500k | 100000 | 2501 | 107 | 677 | 45 | 219 | 105 |

- The filter is `level=ERROR`, counted on every page then shown; the group is by `request_id` over its matches.
- 100k entries is paging.size, the most the view takes; longest stall is over every run, as a 1ms timer sees it.
