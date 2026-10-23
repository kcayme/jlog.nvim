# jlog benchmark

Median of 5 runs after 1 warm-up; NVIM v0.12.6; jq-1.8.2.

| input | contender | median ms | entries/s | Lua MB after parse |
|---|---|---:|---:|---:|
| jsonl 10k | jlog parse only | 63 | 159078 | 0 |
| jsonl 10k | jlog parse + compact render | 80 | 124494 | - |
| jsonl 10k | jlog parse + expanded render | 170 | 58963 | - |
| jsonl 10k | vim.json.decode per line (pure lines) | 13 | 746935 | - |
| jsonl 10k | jq -c . (pure lines) | 54 | 186563 | - |
| jsonl 10k | jq . (pure lines) | 58 | 173593 | - |
| jsonl 100k | jlog parse only | 1119 | 89391 | 5 |
| jsonl 100k | jlog parse + compact render | 1468 | 68113 | - |
| jsonl 100k | jlog parse + expanded render | 3074 | 32534 | - |
| jsonl 100k | vim.json.decode per line (pure lines) | 173 | 577480 | - |
| jsonl 100k | jq -c . (pure lines) | 498 | 200707 | - |
| jsonl 100k | jq . (pure lines) | 534 | 187124 | - |
| jsonl 500k | jlog parse only | 5505 | 90831 | 44 |
| jsonl 500k | jlog parse + compact render | 6899 | 72479 | - |
| jsonl 500k | jlog parse + expanded render | 15619 | 32013 | - |
| jsonl 500k | vim.json.decode per line (pure lines) | 937 | 533782 | - |
| jsonl 500k | jq -c . (pure lines) | 2468 | 202606 | - |
| jsonl 500k | jq . (pure lines) | 2629 | 190164 | - |
| loki 10k | jlog parse only | 147 | 67863 | 2 |
| loki 10k | jlog parse + compact render | 169 | 59342 | - |
| loki 10k | jlog parse + expanded render | 355 | 28176 | - |
| loki 10k | vim.json.decode array + line | 25 | 399715 | - |
| loki 10k | jq -c '.[] \| .line \| fromjson? // .' | 82 | 121537 | - |
| loki 100k | jlog parse only | 2010 | 49743 | 73 |
| loki 100k | jlog parse + compact render | 2418 | 41363 | - |
| loki 100k | jlog parse + expanded render | 4810 | 20788 | - |
| loki 100k | vim.json.decode array + line | 429 | 233235 | - |
| loki 100k | jq -c '.[] \| .line \| fromjson? // .' | 806 | 124005 | - |
| loki 500k | jlog parse only | 10943 | 45691 | 388 |
| loki 500k | jlog parse + compact render | 12751 | 39213 | - |
| loki 500k | jlog parse + expanded render | 25221 | 19824 | - |
| loki 500k | vim.json.decode array + line | 1972 | 253534 | - |
| loki 500k | jq -c '.[] \| .line \| fromjson? // .' | 3995 | 125166 | - |

jq does not build jlog's entry model or continuation lines.
jq and `vim.json.decode` rows read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines.
Lua MB after parse is approximate: LuaJIT interns strings, so entry strings that equal the input text add nothing.
