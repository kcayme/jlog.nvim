# jlog benchmark

Median of 5 runs after 1 warm-up; NVIM v0.12.6; jq-1.8.2.

## Parsing vs jq

Each contender reads the whole input into records.

| input | contender | median ms | entries/s | Lua MB after parse |
|---|---|---:|---:|---:|
| jsonl 10k | jlog parse only | 64 | 155668 | 0 |
| jsonl 10k | jlog parse + compact render | 80 | 125377 | - |
| jsonl 10k | jlog parse + expanded render | 173 | 57852 | - |
| jsonl 10k | vim.json.decode per line (pure lines) | 12 | 867221 | - |
| jsonl 10k | jq -c . (pure lines) | 53 | 187452 | - |
| jsonl 10k | jq . (pure lines) | 57 | 174533 | - |
| jsonl 100k | jlog parse only | 1075 | 93028 | 4 |
| jsonl 100k | jlog parse + compact render | 1417 | 70562 | - |
| jsonl 100k | jlog parse + expanded render | 3078 | 32488 | - |
| jsonl 100k | vim.json.decode per line (pure lines) | 129 | 777059 | - |
| jsonl 100k | jq -c . (pure lines) | 498 | 200890 | - |
| jsonl 100k | jq . (pure lines) | 533 | 187477 | - |
| jsonl 500k | jlog parse only | 5357 | 93329 | 38 |
| jsonl 500k | jlog parse + compact render | 7196 | 69483 | - |
| jsonl 500k | jlog parse + expanded render | 15753 | 31739 | - |
| jsonl 500k | vim.json.decode per line (pure lines) | 889 | 562427 | - |
| jsonl 500k | jq -c . (pure lines) | 2473 | 202185 | - |
| jsonl 500k | jq . (pure lines) | 2638 | 189561 | - |

jq does not build jlog's entry model or continuation lines.
jq and `vim.json.decode` rows read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines.
Lua MB after parse is approximate: LuaJIT interns strings, so entry strings that equal the input text add nothing.

## Workspace

What a user waits for in the plugin; nothing in jq or `vim.json.decode` does the same work.

| input | action | median ms | entries/s |
|---|---|---:|---:|
| jsonl 10k | open -> first screen | 17 | - |
| jsonl 10k | search licence (page) | 5 | 2178055 |
| jsonl 10k | group by request_id (page) | 27 | 370000 |
| jsonl 100k | open -> first screen | 38 | - |
| jsonl 100k | search licence (page) | 72 | 1366547 |
| jsonl 100k | group by request_id (page) | 242 | 404728 |
| jsonl 500k | open -> first screen | 91 | - |
| jsonl 500k | search licence (page) | 107 | 917133 |
| jsonl 500k | group by request_id (page) | 274 | 358502 |

Rows run on the page a file opens on (page 1, the newest; at most paging.size plus overlap).
Their entries/s is entries on that page per second; open is to the first screen, not the whole load.
