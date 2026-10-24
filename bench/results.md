# jlog benchmark

Median of 5 runs after 1 warm-up; NVIM v0.12.6; jq-1.8.2.

## Parsing vs jq

Median ms for each contender to read the whole input into records.

| input | jlog (ms) | vim.json.decode (ms) | jq (ms) |
|---|---:|---:|---:|
| jsonl 10k | 78 | 12 | 53 |
| jsonl 100k | 1082 | 131 | 499 |
| jsonl 500k | 5267 | 871 | 2475 |

jlog builds its entries and each entry's field tree; it keeps key order and number literals as written.
vim.json.decode decodes each line; jq runs `jq -c .`.
jq does not build jlog's entry model or continuation lines.
vim.json.decode and jq read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines.

## Workspace

What a user waits for in the plugin, in median ms; nothing in jq or `vim.json.decode` does the same work.

| input | open to screen (ms) | search (ms) | filter (ms) | group (ms) |
|---|---:|---:|---:|---:|
| jsonl 10k | 17 | 5 | 6 | 27 |
| jsonl 100k | 38 | 70 | 81 | 243 |
| jsonl 500k | 93 | 107 | 117 | 270 |

Search is the bare term `licence`, filter is `status>=500`, group is by `request_id`.
Search, filter and group run on the page a file opens on (page 1, the newest; at most paging.size plus overlap).
Open to screen stops at the first screen, not the whole load.
