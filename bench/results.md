# jlog benchmark

Median of 5 runs after 1 warm-up; NVIM v0.12.6; jq-1.8.2.

| input | contender | median ms | entries/s | Lua MB after parse |
|---|---|---:|---:|---:|
| jsonl 10k | jlog parse only | 64 | 155668 | 0 |
| jsonl 10k | jlog parse + compact render | 80 | 125377 | - |
| jsonl 10k | jlog parse + expanded render | 173 | 57852 | - |
| jsonl 10k | workspace open -> first screen | 17 | - | - |
| jsonl 10k | workspace search licence (page) | 5 | 2178055 | - |
| jsonl 10k | workspace group by request_id (page) | 27 | 370000 | - |
| jsonl 10k | vim.json.decode per line (pure lines) | 12 | 867221 | - |
| jsonl 10k | jq -c . (pure lines) | 53 | 187452 | - |
| jsonl 10k | jq . (pure lines) | 57 | 174533 | - |
| jsonl 100k | jlog parse only | 1075 | 93028 | 4 |
| jsonl 100k | jlog parse + compact render | 1417 | 70562 | - |
| jsonl 100k | jlog parse + expanded render | 3078 | 32488 | - |
| jsonl 100k | workspace open -> first screen | 38 | - | - |
| jsonl 100k | workspace search licence (page) | 72 | 1366547 | - |
| jsonl 100k | workspace group by request_id (page) | 242 | 404728 | - |
| jsonl 100k | vim.json.decode per line (pure lines) | 129 | 777059 | - |
| jsonl 100k | jq -c . (pure lines) | 498 | 200890 | - |
| jsonl 100k | jq . (pure lines) | 533 | 187477 | - |
| jsonl 500k | jlog parse only | 5357 | 93329 | 38 |
| jsonl 500k | jlog parse + compact render | 7196 | 69483 | - |
| jsonl 500k | jlog parse + expanded render | 15753 | 31739 | - |
| jsonl 500k | workspace open -> first screen | 91 | - | - |
| jsonl 500k | workspace search licence (page) | 107 | 917133 | - |
| jsonl 500k | workspace group by request_id (page) | 274 | 358502 | - |
| jsonl 500k | vim.json.decode per line (pure lines) | 889 | 562427 | - |
| jsonl 500k | jq -c . (pure lines) | 2473 | 202185 | - |
| jsonl 500k | jq . (pure lines) | 2638 | 189561 | - |
| loki 10k | jlog parse only | 110 | 91200 | 4 |
| loki 10k | jlog parse + compact render | 131 | 76563 | - |
| loki 10k | jlog parse + expanded render | 416 | 24046 | - |
| loki 10k | workspace open -> first screen | 39 | - | - |
| loki 10k | workspace search licence (page) | 6 | 1622784 | - |
| loki 10k | workspace group by request_id (page) | 42 | 236971 | - |
| loki 10k | vim.json.decode array + line | 24 | 413377 | - |
| loki 10k | jq -c '.[] \| .line \| fromjson? // .' | 82 | 121484 | - |
| loki 100k | jlog parse only | 2037 | 49103 | 55 |
| loki 100k | jlog parse + compact render | 2465 | 40573 | - |
| loki 100k | jlog parse + expanded render | 5071 | 19720 | - |
| loki 100k | workspace open -> first screen | 66 | - | - |
| loki 100k | workspace search licence (page) | 166 | 604086 | - |
| loki 100k | workspace group by request_id (page) | 476 | 209873 | - |
| loki 100k | vim.json.decode array + line | 273 | 366439 | - |
| loki 100k | jq -c '.[] \| .line \| fromjson? // .' | 830 | 120509 | - |
| loki 500k | jlog parse only | 10789 | 46345 | 281 |
| loki 500k | jlog parse + compact render | 13294 | 37610 | - |
| loki 500k | jlog parse + expanded render | 27000 | 18518 | - |
| loki 500k | workspace open -> first screen | 119 | - | - |
| loki 500k | workspace search licence (page) | 179 | 569700 | - |
| loki 500k | workspace group by request_id (page) | 536 | 190440 | - |
| loki 500k | vim.json.decode array + line | 1563 | 319911 | - |
| loki 500k | jq -c '.[] \| .line \| fromjson? // .' | 4071 | 122827 | - |

jq does not build jlog's entry model or continuation lines.
Workspace rows run on the page a file opens on (page 1, the newest; at most paging.size plus overlap).
Their entries/s is entries on that page per second; open is to the first screen, not the whole load.
jq and `vim.json.decode` rows read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines.
Lua MB after parse is approximate: LuaJIT interns strings, so entry strings that equal the input text add nothing.
