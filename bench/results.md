# jlog benchmark

Median of 5 runs after 1 warm-up; NVIM v0.12.6; jq-1.8.2.

## Parsing vs jq

Each contender reads the whole input into records.

| input | contender | median ms | entries/s | Lua MB after parse |
|---|---|---:|---:|---:|
| jsonl 10k | jlog parse only | 69 | 145728 | 0 |
| jsonl 10k | vim.json.decode per line (pure lines) | 11 | 885630 | - |
| jsonl 10k | jq -c . (pure lines) | 53 | 187642 | - |
| jsonl 100k | jlog parse only | 1087 | 92029 | 4 |
| jsonl 100k | vim.json.decode per line (pure lines) | 132 | 758754 | - |
| jsonl 100k | jq -c . (pure lines) | 495 | 201901 | - |
| jsonl 500k | jlog parse only | 5380 | 92932 | 38 |
| jsonl 500k | vim.json.decode per line (pure lines) | 848 | 589812 | - |
| jsonl 500k | jq -c . (pure lines) | 2464 | 202959 | - |
| array 10k | jlog parse only | 49 | 203859 | -1 |
| array 10k | vim.json.decode array | 11 | 916557 | - |
| array 10k | jq -c '.[]' | 64 | 156668 | - |
| array 100k | jlog parse only | 1006 | 99438 | 23 |
| array 100k | vim.json.decode array | 117 | 852546 | - |
| array 100k | jq -c '.[]' | 645 | 155070 | - |
| array 500k | jlog parse only | 4932 | 101386 | 129 |
| array 500k | vim.json.decode array | 765 | 653232 | - |
| array 500k | jq -c '.[]' | 3228 | 154897 | - |

jq does not build jlog's entry model or continuation lines.
jq and `vim.json.decode` rows read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines.
Lua MB after parse is approximate: LuaJIT interns strings, so entry strings that equal the input text add nothing.

## Workspace

What a user waits for in the plugin; nothing in jq or `vim.json.decode` does the same work.

| input | action | median ms | entries/s |
|---|---|---:|---:|
| jsonl 10k | open -> first screen | 18 | - |
| jsonl 10k | search licence (page) | 5 | 2076092 |
| jsonl 10k | group by request_id (page) | 28 | 356384 |
| jsonl 100k | open -> first screen | 38 | - |
| jsonl 100k | search licence (page) | 76 | 1297694 |
| jsonl 100k | group by request_id (page) | 244 | 401746 |
| jsonl 500k | open -> first screen | 90 | - |
| jsonl 500k | search licence (page) | 105 | 931522 |
| jsonl 500k | group by request_id (page) | 268 | 365363 |
| array 10k | open -> first screen | 38 | - |
| array 10k | search licence (page) | 5 | 2139384 |
| array 10k | group by request_id (page) | 27 | 367265 |
| array 100k | open -> first screen | 158 | - |
| array 100k | search licence (page) | 111 | 901358 |
| array 100k | group by request_id (page) | 322 | 310462 |
| array 500k | open -> first screen | 200 | - |
| array 500k | search licence (page) | 120 | 848703 |
| array 500k | group by request_id (page) | 355 | 287213 |

Rows run on the page a file opens on (page 1, the newest; at most paging.size plus overlap).
Their entries/s is entries on that page per second; open is to the first screen, not the whole load.
