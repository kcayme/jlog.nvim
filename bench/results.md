# jlog benchmark

Median of 5 runs after 1 warm-up; NVIM v0.12.6; jq-1.8.2.

## Parsing vs jq

Median ms for each contender to read the whole input into records.

| input | jlog load (ms) | jlog + field tree (ms) | vim.json.decode (ms) | jq (ms) |
|---|---:|---:|---:|---:|
| jsonl 10k | 31 | 62 | 11 | 54 |
| jsonl 100k | 421 | 1011 | 129 | 501 |
| jsonl 500k | 1944 | 4984 | 872 | 2479 |

- jlog load is what opening a file does: split lines, keep prefixes and continuation lines, and find each line's JSON with vim.json.decode.
- jlog + field tree adds jlog's own parse, which keeps key order and number literals as written, and unwraps double-encoded JSON; the plugin does this only for the lines it renders.
- vim.json.decode decodes each line and jq runs `jq -c .`; neither keeps key order or number literals.
- vim.json.decode and jq read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines.

## Workspace

What a user waits for in the plugin, in median ms; nothing in jq or `vim.json.decode` does the same work.

| input | open to screen (ms) | search (ms) | filter (ms) | group (ms) |
|---|---:|---:|---:|---:|
| jsonl 10k | 18 | 5 | 6 | 27 |
| jsonl 100k | 38 | 75 | 85 | 248 |
| jsonl 500k | 90 | 108 | 116 | 271 |

- Search is the bare term `licence`, filter is `status>=500`, group is by `request_id`.
- Search, filter and group run on the page a file opens on (page 1, the newest; at most paging.size plus overlap).
- Open to screen stops at the first screen, not the whole load.
