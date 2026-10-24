# jlog benchmark

Median of 5 runs after 1 warm-up; NVIM v0.12.6; jq-1.8.2.

## Parsing vs jq

Median ms for each contender to read the whole input into records.

| input | jlog | vim.json.decode | jq | jlog Lua MB |
|---|---:|---:|---:|---:|
| jsonl 10k | 78 | 12 | 53 | 0 |
| jsonl 100k | 1082 | 131 | 499 | 4 |
| jsonl 500k | 5267 | 871 | 2475 | 38 |
| array 10k | 54 | 11 | 63 | -1 |
| array 100k | 921 | 120 | 648 | 24 |
| array 500k | 5201 | 795 | 3211 | 127 |

jlog builds its entries and each entry's field tree; it keeps key order and number literals as written.
vim.json.decode decodes each line (jsonl) or the whole array; jq runs `jq -c .` (jsonl) or `jq -c '.[]'` (array).
jq does not build jlog's entry model or continuation lines.
For jsonl, vim.json.decode and jq read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines.
jlog Lua MB is approximate: LuaJIT interns strings, so entry strings that equal the input text add nothing.

## Workspace

What a user waits for in the plugin, in median ms; nothing in jq or `vim.json.decode` does the same work.

| input | open to screen | search | filter | group |
|---|---:|---:|---:|---:|
| jsonl 10k | 17 | 5 | 6 | 27 |
| jsonl 100k | 38 | 70 | 81 | 243 |
| jsonl 500k | 93 | 107 | 117 | 270 |
| array 10k | 39 | 5 | 6 | 27 |
| array 100k | 158 | 118 | 125 | 333 |
| array 500k | 201 | 123 | 136 | 361 |

Search is the bare term `licence`, filter is `status>=500`, group is by `request_id`.
Search, filter and group run on the page a file opens on (page 1, the newest; at most paging.size plus overlap).
Open to screen stops at the first screen, not the whole load.
