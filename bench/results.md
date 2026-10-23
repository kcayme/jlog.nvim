# jlog benchmark

Median of 5 runs after 1 warm-up; NVIM v0.12.6; jq-1.8.2.

| input | contender | median ms | entries/s | Lua MB after parse |
|---|---|---:|---:|---:|
| jsonl 10k | jlog parse only | 61 | 165048 | 0 |
| jsonl 10k | jlog parse + compact render | 83 | 120269 | - |
| jsonl 10k | jlog parse + expanded render | 182 | 54875 | - |
| jsonl 10k | vim.json.decode per line (pure lines) | 13 | 781587 | - |
| jsonl 10k | jq -c . (pure lines) | 53 | 188277 | - |
| jsonl 10k | jq . (pure lines) | 57 | 174636 | - |
| jsonl 100k | jlog parse only | 1092 | 91588 | 5 |
| jsonl 100k | jlog parse + compact render | 1398 | 71522 | - |
| jsonl 100k | jlog parse + expanded render | 3031 | 32987 | - |
| jsonl 100k | vim.json.decode per line (pure lines) | 165 | 606704 | - |
| jsonl 100k | jq -c . (pure lines) | 501 | 199786 | - |
| jsonl 100k | jq . (pure lines) | 533 | 187470 | - |
| jsonl 500k | jlog parse only | 5537 | 90308 | 44 |
| jsonl 500k | jlog parse + compact render | 7009 | 71341 | - |
| jsonl 500k | jlog parse + expanded render | 15745 | 31756 | - |
| jsonl 500k | vim.json.decode per line (pure lines) | 922 | 542242 | - |
| jsonl 500k | jq -c . (pure lines) | 2460 | 203226 | - |
| jsonl 500k | jq . (pure lines) | 2647 | 188891 | - |
| loki 5k | jlog parse only | 61 | 81800 | -2 |
| loki 5k | jlog parse + compact render | 67 | 74514 | - |
| loki 5k | jlog parse + expanded render | 141 | 35354 | - |
| loki 5k | vim.json.decode array + line | 11 | 473065 | - |
| loki 5k | jq -c '.[] | .line | fromjson? // .' | 42 | 118547 | - |

jq does not build jlog's entry model or continuation lines.
jq and `vim.json.decode` rows read a prefix-free copy of the same lines, since they cannot parse prefixed or continuation lines.
Lua MB after parse is approximate: LuaJIT interns strings, so entry strings that equal the input text add nothing.
