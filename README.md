# jlog.nvim

Read JSON server logs in Neovim. Logs pulled from CI and Grafana are often unformatted, one giant line, and
double-encoded; jlog makes them readable, filterable and groupable without leaving the editor.

## Features

- Parses Grafana/Loki "Explore" exports, JSONL/NDJSON and JSON arrays of log objects.
- Unwraps double-encoded JSON recursively, including JSON after a text prefix inside a string.
- Compact one-line-per-entry view by default, toggle to expanded (indented JSON) per entry or for the whole view.
- Field filtering with a small query language, including `OR`.
- Group by any field (request id, status, route, ...).
- Native `/` search, `n`, `N` and `:g` work on the rendered text.
- Workspace in its own tab with a sidebar for filters, group-by and field browsing.
- `:JLog` opens the current buffer or a file path as a workspace.
- Re-renders when the source file changes.
- Stays fast on huge files; key order and number literals are never altered, nothing in the source is dropped.

## Requirements

- Neovim >= 0.10
- No external tools (no jq, no treesitter)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "kcayme/jlog.nvim" }
```

## Usage

Open a log file and run `:JLog` in its buffer, or run `:JLog {path}`. jlog never writes to the source file.

The newest entries come first by default, for JSONL files (oldest line at the top) and Grafana exports (newest
element first) alike; `R` toggles the order and `view.sort = "asc"` makes oldest first the default. Within a group,
entries also run newest first.

The view reloads automatically when the file changes: appended lines are streamed in, and atomic saves (write to a
temp file, then rename) are followed. Large JSONL files, and newest-first Grafana exports shown in the default order,
show the first screen immediately and finish loading in the background; meanwhile FIELDS adds newly found fields as
they appear, marked `loading N%` until the counts are final. An oldest-first Grafana export, or any Grafana export
with `view.sort = "asc"`, appears once loading finishes.

Type filters under `FILTERS` and a field under `GROUP BY` in the sidebar, then `:w` to apply (leaving insert mode
also applies). An empty section shows an example in normal mode.

A search or group shows its lines first; FIELDS counts arrive afterwards. Until they do, FIELDS keeps the previous
counts, dimmed with `JLogFieldStale` and marked `counting…`. With the sidebar closed nothing is counted.

A log larger than `paging.size` (100k lines or array elements by default) is shown one page at a time, so only the
current page is parsed and held. Page 1 holds the newest entries (the oldest with `view.sort = "asc"`). The winbar
shows `page 2/5`, or `page 1/…` while the page boundaries are still being found. Each page also shows
`paging.overlap` lines or elements of its neighbours, dimmed with `JLogOverlap`, so a request at a page edge stays
whole; filters, groups and FIELDS counts include them. Filters, group and mode carry over to another page; the cursor
and expanded entries reset. Appended lines show on the page that holds the end of the file; on any other page only
the page count updates. A rewritten file returns to the page holding the cursor entry. A Grafana export whose
timestamps are not in order is not paged.

### Commands

| Command | Action |
|---------|--------|
| `:JLog` | Open a workspace for the current buffer (no-op if one is already open in this tab). |
| `:JLog {path}` | Open a log file. |
| `:JLog filter {clause}` | Add a filter clause (see below). |
| `:JLog filter` | Clear all filter clauses. |
| `:JLog group {field}` | Group entries by a field. |
| `:JLog group` | Clear grouping. |
| `:JLog page {n}` | Go to page `n` of a paged log. |
| `:JLog raw` | Open the source in a new tab. |
| `:JLog close` | Close the workspace. |

### Keymaps

Buffer-local, configurable under `keymaps`; set any to `false` to disable it.

| Key | Where | Action |
|-----|-------|--------|
| `<Tab>` | log view | Expand/collapse the entry under the cursor |
| `E` | log view | Toggle the whole view between compact and expanded |
| `gf` | log view | Show the entry's raw source text in a float (press again in the float to jump to the source line, JSONL only) |
| `R` | log view | Reverse order |
| `]]` / `[[` | log view | Next / previous entry |
| `]e` / `[e` | log view | Next / previous ERROR-level entry |
| `]p` / `[p` | log view | Next / previous page of a paged log |
| `s` | log view | Focus the sidebar |
| `S` | log view | Toggle the sidebar |
| `q` | log view, sidebar | Close the workspace (closes the float in the raw popup) |
| `<CR>` | sidebar | On a field value, add it as a filter |
| `g` | sidebar | On a field, group by it |

### Filter syntax

One clause per `:JLog filter` call or sidebar `FILTERS` line:

```
:JLog filter status>=500 path=/api/licence-checks
```

| Syntax | Meaning |
|--------|---------|
| `field=value`, `field!=value` | Equality on the value's text; numbers also compare numerically (`status=500`). |
| `field>n`, `>=`, `<`, `<=` | Numeric comparison; non-numeric values never match. |
| `field~regex` | Vim regex (same flavor as `/`, honors `'ignorecase'`) against the field's string form. |
| `value` | Bare term: Vim regex against the entry's raw source text. |
| `-term` | Negate a term. |
| `term term` | Space means AND. |
| `a OR b` | Uppercase `OR` separates alternatives; AND binds tighter. |
| `"quoted value"` | Needed for spaces or the word `OR`, e.g. `msg="request completed"`. |

- Fields are dotted paths (`req.headers.host`). `time`, `level` and `msg` resolve through the configured `fields`
  aliases (e.g. `message`, `severity`). `level` compares case-insensitively.
- In field names (filters, GROUP BY, FIELDS) a newline is written `\n` and a backslash `\\`.
- A missing field never matches, so `-term` matches it.
- Multiple sidebar lines are ANDed.
- Inside quotes only `\"`, `\\` and `\n` are escapes; `\\` is one backslash and `\n` is a newline (a facet value
  with a newline becomes `field="a\nb"`). A quoted `~` regex that needs a literal backslash must therefore write
  `\\\\`, e.g. `msg~"a\\\\b"` matches `a\b`.
- Integers are exact at any size: past 2^53 (where doubles stop holding every integer) `=`, `~`, groups and
  FIELDS use the literal as written, so `id=12345678901234567890` works. `>`, `>=`, `<` and `<=` compare as
  doubles, so beyond 2^53 they are approximate.
- Filtering while grouped keeps whole groups: a group is shown if any of its entries matches.

## Configuration

Defaults (all optional):

```lua
require("jlog").setup({
  fields = {
    time = { "time", "ts", "timestamp", "@timestamp" },
    level = { "level", "lvl", "severity" },
    message = { "msg", "message" },
  },
  view = { mode = "compact", sort = "desc" }, -- "desc" shows the newest entries first
  unwrap = { enable = true, max_depth = 4 },
  sidebar = { width = 40, position = "right" },
  facets = { top_values = 10 },
  paging = { size = 100000, overlap = 2000 }, -- source lines (JSONL) or array elements
  keymaps = {
    toggle_entry = "<Tab>",
    toggle_mode = "E",
    raw = "gf",
    reverse = "R",
    next_entry = "]]",
    prev_entry = "[[",
    next_error = "]e",
    prev_error = "[e",
    next_page = "]p",
    prev_page = "[p",
    focus_sidebar = "s",
    toggle_sidebar = "S",
    close = "q",
    add_filter = "<CR>",
    group_by = "g",
  },
})
```

See [docs/options.md](docs/options.md) for every option.

## Highlight groups

All groups are defined with `default = true` and re-applied on `ColorScheme`. Level groups are badges: the
linked group's color, reversed and bold, so the level reads as a colored label in compact lines. Override them with
`vim.api.nvim_set_hl(0, "JLogLevelError", { ... })` or `:hi`.

| Group | Used for | Default link |
|-------|----------|--------------|
| `JLogTime` | timestamp in compact lines | `Comment` |
| `JLogLevelError` | ERROR / FATAL / PANIC | badge: `DiagnosticError` color as background |
| `JLogLevelWarn` | WARN / WARNING | badge: `DiagnosticWarn` color as background |
| `JLogLevelInfo` | INFO | badge: `DiagnosticInfo` color as background |
| `JLogLevelDebug` | DEBUG | badge: `DiagnosticHint` color as background |
| `JLogLevelTrace` | TRACE and unknown levels | badge: `Comment` color as background |
| `JLogMessage` | message text | `Normal` |
| `JLogKey` | `key=` in compact, object keys in expanded | `Identifier` |
| `JLogValue` | compact values | `String` |
| `JLogString` | expanded string values | `String` |
| `JLogNumber` | expanded number values | `Number` |
| `JLogBoolean` | expanded boolean values | `Boolean` |
| `JLogNull` | expanded null values | `Constant` |
| `JLogPrefix` | text before embedded JSON | `Comment` |
| `JLogPlain` | non-JSON entries and continuation lines | `Comment` |
| `JLogGroupHeader` | group header lines | `Title` |
| `JLogSectionHeader` | sidebar `FILTERS` / `GROUP BY` / `FIELDS` | `Title` |
| `JLogFieldName` | field names in the FIELDS section | `Identifier` |
| `JLogFieldCount` | counts in the FIELDS section | `Comment` |
| `JLogFieldStale` | FIELDS counts kept from the last apply while new ones are counted | `NonText` |
| `JLogHint` | sidebar examples on empty FILTERS / GROUP BY lines and `:w to apply` | `Comment` |
| `JLogWinbar` | jlog winbar text | `WinBar` |
| `JLogOverlap` | entries a page shares with its neighbours | `Comment` |

## Benchmark

jlog is compared against `jq` and `vim.json.decode` on 10k to 500k line files; see
[bench/results.md](bench/results.md). `make bench` regenerates it (jq is needed for the comparison rows).
