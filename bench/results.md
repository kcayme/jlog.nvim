# jlog benchmark

Median of 5 runs after 1 warm-up; NVIM v0.12.6; jq-1.8.2.

| input | contender | median ms | entries/s | Lua MB after parse |
|---|---|---:|---:|---:|
| jsonl 10k | jlog parse only | 70 | 142472 | 0 |
| jsonl 10k | jlog parse + compact render | 91 | 110456 | - |
| jsonl 10k | jlog parse + expanded render | 206 | 48602 | - |
| jsonl 10k | workspace open -> first screen | 21 | - | - |
| jsonl 10k | workspace search licence (page) | 7 | 1527268 | - |
| jsonl 10k | workspace group by request_id (page) | 36 | 278951 | - |
| jsonl 10k | vim.json.decode per line (pure lines) | 12 | 855292 | - |
| jsonl 10k | jq -c . (pure lines) | 54 | 185370 | - |
| jsonl 10k | jq . (pure lines) | 58 | 172759 | - |
| jsonl 100k | jlog parse only | 1157 | 86414 | 4 |
| jsonl 100k | jlog parse + compact render | 1511 | 66201 | - |
| jsonl 100k | jlog parse + expanded render | 3181 | 31440 | - |
| jsonl 100k | workspace open -> first screen | 47 | - | - |
| jsonl 100k | workspace search licence (page) | 131 | 748719 | - |
| jsonl 100k | workspace group by request_id (page) | 373 | 263291 | - |
| jsonl 100k | vim.json.decode per line (pure lines) | 140 | 713966 | - |
| jsonl 100k | jq -c . (pure lines) | 498 | 200769 | - |
| jsonl 100k | jq . (pure lines) | 534 | 187432 | - |
| jsonl 500k | jlog parse only | 5450 | 91737 | 40 |
| jsonl 500k | jlog parse + compact render | 7061 | 70811 | - |
| jsonl 500k | jlog parse + expanded render | 14904 | 33549 | - |
| jsonl 500k | workspace open -> first screen | 99 | - | - |
| jsonl 500k | workspace search licence (page) | 248 | 394852 | - |
| jsonl 500k | workspace group by request_id (page) | 465 | 211132 | - |
| jsonl 500k | vim.json.decode per line (pure lines) | 695 | 719282 | - |
| jsonl 500k | jq -c . (pure lines) | 2487 | 201071 | - |
| jsonl 500k | jq . (pure lines) | 2666 | 187532 | - |
| loki 10k | jlog parse only | 103 | 97170 | 5 |
| loki 10k | jlog parse + compact render | 124 | 80724 | - |
| loki 10k | jlog parse + expanded render | 296 | 33794 | - |
| loki 10k | workspace open -> first screen | 42 | - | - |
| loki 10k | workspace search licence (page) | 7 | 1523710 | - |
| loki 10k | workspace group by request_id (page) | 36 | 277325 | - |
| loki 10k | vim.json.decode array + line | 23 | 427736 | - |
| loki 10k | jq -c '.[] \| .line \| fromjson? // .' | 84 | 119510 | - |
| loki 100k | jlog parse only | 2051 | 48751 | 55 |
| loki 100k | jlog parse + compact render | 2309 | 43308 | - |
| loki 100k | jlog parse + expanded render | 4771 | 20960 | - |
| loki 100k | workspace open -> first screen | 61 | - | - |
| loki 100k | workspace search licence (page) | 179 | 559782 | - |
| loki 100k | workspace group by request_id (page) | 393 | 254755 | - |
| loki 100k | vim.json.decode array + line | 277 | 361183 | - |
| loki 100k | jq -c '.[] \| .line \| fromjson? // .' | 814 | 122853 | - |
| loki 500k | jlog parse only | 10774 | 46410 | 281 |
| loki 500k | jlog parse + compact render | 12628 | 39595 | - |
| loki 500k | jlog parse + expanded render | 25720 | 19440 | - |
| loki 500k | workspace open -> first screen | 117 | - | - |
| loki 500k | workspace search licence (page) | 168 | 608543 | - |
| loki 500k | workspace group by request_id (page) | 398 | 256528 | - |
| loki 500k | vim.json.decode array + line | 1899 | 263275 | - |
| loki 500k | jq -c '.[] \| .line \| fromjson? // .' | 4068 | 122903 | - |

jq does not build jlog's entry model or continuation lines.
Workspace rows run on the page a file opens on (page 1, the newest; at most paging.size plus overlap).
Their entries/s is entries on that page per second; open is to the first screen, not the whole load.
jq and `vim.json.decode` rows read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines.
Lua MB after parse is approximate: LuaJIT interns strings, so entry strings that equal the input text add nothing.
