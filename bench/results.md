# jlog benchmark

Median of 5 runs after 1 warm-up; NVIM v0.12.6; jq-1.8.2.

| input | contender | median ms | entries/s | Lua MB after parse |
|---|---|---:|---:|---:|
| jsonl 10k | jlog parse only | 65 | 154314 | 0 |
| jsonl 10k | jlog parse + compact render | 83 | 120418 | - |
| jsonl 10k | jlog parse + expanded render | 176 | 56860 | - |
| jsonl 10k | workspace open -> first screen | 20 | - | - |
| jsonl 10k | workspace search licence (page) | 6 | 1655665 | - |
| jsonl 10k | workspace group by request_id (page) | 35 | 287220 | - |
| jsonl 10k | vim.json.decode per line (pure lines) | 12 | 868614 | - |
| jsonl 10k | jq -c . (pure lines) | 53 | 188052 | - |
| jsonl 10k | jq . (pure lines) | 57 | 175149 | - |
| jsonl 100k | jlog parse only | 1101 | 90841 | 4 |
| jsonl 100k | jlog parse + compact render | 1445 | 69191 | - |
| jsonl 100k | jlog parse + expanded render | 3014 | 33182 | - |
| jsonl 100k | workspace open -> first screen | 47 | - | - |
| jsonl 100k | workspace search licence (page) | 125 | 784590 | - |
| jsonl 100k | workspace group by request_id (page) | 366 | 268183 | - |
| jsonl 100k | vim.json.decode per line (pure lines) | 140 | 714877 | - |
| jsonl 100k | jq -c . (pure lines) | 498 | 200889 | - |
| jsonl 100k | jq . (pure lines) | 533 | 187686 | - |
| jsonl 500k | jlog parse only | 5498 | 90937 | 40 |
| jsonl 500k | jlog parse + compact render | 7371 | 67831 | - |
| jsonl 500k | jlog parse + expanded render | 15536 | 32183 | - |
| jsonl 500k | workspace open -> first screen | 102 | - | - |
| jsonl 500k | workspace search licence (page) | 268 | 365588 | - |
| jsonl 500k | workspace group by request_id (page) | 487 | 201341 | - |
| jsonl 500k | vim.json.decode per line (pure lines) | 721 | 693720 | - |
| jsonl 500k | jq -c . (pure lines) | 2465 | 202846 | - |
| jsonl 500k | jq . (pure lines) | 2671 | 187187 | - |
| loki 10k | jlog parse only | 113 | 88397 | 5 |
| loki 10k | jlog parse + compact render | 128 | 78236 | - |
| loki 10k | jlog parse + expanded render | 303 | 32983 | - |
| loki 10k | workspace open -> first screen | 47 | - | - |
| loki 10k | workspace search licence (page) | 7 | 1463904 | - |
| loki 10k | workspace group by request_id (page) | 107 | 93667 | - |
| loki 10k | vim.json.decode array + line | 25 | 406293 | - |
| loki 10k | jq -c '.[] \| .line \| fromjson? // .' | 84 | 118350 | - |
| loki 100k | jlog parse only | 2080 | 48082 | 53 |
| loki 100k | jlog parse + compact render | 2550 | 39214 | - |
| loki 100k | jlog parse + expanded render | 4849 | 20621 | - |
| loki 100k | workspace open -> first screen | 63 | - | - |
| loki 100k | workspace search licence (page) | 165 | 604366 | - |
| loki 100k | workspace group by request_id (page) | 1126 | 88815 | - |
| loki 100k | vim.json.decode array + line | 265 | 377725 | - |
| loki 100k | jq -c '.[] \| .line \| fromjson? // .' | 827 | 120971 | - |
| loki 500k | jlog parse only | 10758 | 46479 | 277 |
| loki 500k | jlog parse + compact render | 12369 | 40423 | - |
| loki 500k | jlog parse + expanded render | 26377 | 18956 | - |
| loki 500k | workspace open -> first screen | 119 | - | - |
| loki 500k | workspace search licence (page) | 178 | 573372 | - |
| loki 500k | workspace group by request_id (page) | 1176 | 86721 | - |
| loki 500k | vim.json.decode array + line | 1877 | 266327 | - |
| loki 500k | jq -c '.[] \| .line \| fromjson? // .' | 4073 | 122752 | - |

jq does not build jlog's entry model or continuation lines.
Workspace rows run on the page a file opens on (page 1, the newest; at most paging.size plus overlap).
Their entries/s is entries on that page per second; open is to the first screen, not the whole load.
jq and `vim.json.decode` rows read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines.
Lua MB after parse is approximate: LuaJIT interns strings, so entry strings that equal the input text add nothing.
