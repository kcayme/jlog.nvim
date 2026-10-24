# jlog.nvim

Read JSON server logs in Neovim. Logs pulled from CI and Grafana are often unformatted, one giant line, and
double-encoded; jlog makes them readable, filterable and groupable without leaving the editor.

## Features

- Parses Grafana/Loki "Explore" exports, JSONL/NDJSON and JSON arrays of log objects.
- Unwraps double-encoded JSON recursively, including JSON after a text prefix inside a string.
- Compact one-line-per-entry view by default, toggle to expanded (indented JSON) per entry or for the whole view.
- Each field keeps one color in the log view and the sidebar's FIELDS list, so FIELDS doubles as a legend.
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

Work that outlasts the first screen (loading, indexing pages, applying a filter or group, rendering) reports through
`vim.notify`: one message when it starts and one when it is done.

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
| `<CR>` | log view | Expand/collapse the entry under the cursor |
| `E` | log view | Toggle the whole view between compact and expanded |
| `gf` | log view | Show the entry's raw source text in a float (press again in the float to jump to the source line, JSONL only) |
| `R` | log view | Reverse order |
| `]]` / `[[` | log view | Next / previous entry |
| `]e` / `[e` | log view | Next / previous ERROR-level entry |
| `]p` / `[p` | log view | Next / previous page of a paged log |
| `s` | log view | Focus the sidebar |
| `S` | log view, sidebar | Toggle the sidebar |
| `q` | log view, sidebar | Close the workspace (closes the float in the raw popup) |
| `<CR>` | sidebar | On a field value, add it as a filter |
| `g` | sidebar | On a field, group by it |
| `?` | sidebar | Open a guide to these keys (`? help` on the sidebar's first line) |

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
    status = { "status", "status_code" }, -- class-colored (2xx-5xx) when styled inverted/pill
  },
  compact = {
    style = "plain", -- "plain" | "inverted" | "pill"; level defaults to "inverted"
    order = {}, -- top-level keys shown first, e.g. { "method", "path", "status" }
    fields = {}, -- per key or role: { style = "pill", format = function(ctx) return ctx.value end }
    pill = { left = "\238\130\182", right = "\238\130\180" }, -- Nerd Font caps; "" for square ends
  },
  view = { mode = "compact", sort = "desc", field_colors = true }, -- "desc" shows the newest entries first
  unwrap = { enable = true, max_depth = 4 },
  sidebar = { width = 40, position = "right" },
  facets = { top_values = 10 },
  paging = { size = 100000, overlap = 2000 }, -- source lines (JSONL) or array elements
  keymaps = {
    toggle_entry = "<CR>",
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
    help = "?",
  },
})
```

See [docs/options.md](docs/options.md) for every option.

### Compact line formatting

Each field of a compact line is drawn in a style, set globally with `compact.style` or per field with
`compact.fields[key].style` (`key` is a field name or one of the roles `time`, `level`, `message`, `status`):

- `plain`: `key=value`, the key colored per field. Example: `method=GET`.
- `inverted`: the value only, as a colored block (the color reversed and bold). Example: ` GET `.
- `pill`: like `inverted`, with rounded caps. Example: `(GET)`.

`level` defaults to `inverted` (the badge); a global `compact.style` other than `"plain"`, or `compact.fields.level`,
overrides that. The global style never applies to `time` or `message`; style them through `compact.fields.time` or
`compact.fields.message`.

Colors: a level takes its `JLogLevel*` color; a field in `fields.status` whose value is `200`-`599` takes its class
color (`JLogStatus2xx` ... `JLogStatus5xx`) when its style is `inverted` or `pill`, e.g.
`compact.fields.status = { style = "inverted" }` (a plain status field keeps its key's field color, unless a format
returns a group); a styled `time` or `message` takes `JLogTime` or `JLogMessage`; any other field takes its key's
field color. Inverted and pill styles draw that color reversed through derived `JLogBadge*` groups.

`compact.order` lists top-level keys to show first, in that order. Dotted names are ignored; `time`, `level`,
`message` and `status` match their role whatever the key is called; role fields not listed stay at the front, and
only a key's first occurrence is placed. A level moved by `order` keeps only its alignment padding before the next
item.

`compact.fields[key].format(ctx)` replaces a field's text. `ctx` has `value`, `key` and `entry`; return the text and,
optionally, a highlight group for it. Newlines in the text are escaped. A formatted `plain` field with no returned
group uses the key's field color. If `format` errors or returns a non-string, the default text is used and jlog warns
once per field, as does a returned group name that is not a valid highlight name. `ctx` is reused between calls, so do
not keep it, and treat `ctx.entry` as read-only. `format` runs on every rendered line, so its cost scales
with the page.

```lua
compact = {
  order = { "method", "path", "status" },
  fields = {
    method = { style = "pill" },
    status = { style = "inverted" },
    duration_ms = {
      format = function(ctx)
        return ctx.value .. "ms", (tonumber(ctx.value) or 0) > 500 and "DiagnosticError" or nil
      end,
    },
  },
}
```

Pill caps are inline virtual text, so yanks and `/` searches never contain them and the cursor skips over them.
They need a Nerd Font; with `pill = { left = "", right = "" }` the pills have square ends.

### Statusline plugins

The log view shows its counts and filters in the winbar. A statusline plugin that draws winbars, such as lualine with
a `winbar` section, replaces it; jlog's buffers have the filetypes `jlog` and `jlog_sidebar` so you can exclude them:

```lua
require("lualine").setup({
  options = { disabled_filetypes = { winbar = { "jlog", "jlog_sidebar" } } },
})
```

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
| `JLogStatus2xx` | status field with a 2xx value, in compact lines | `DiagnosticOk` |
| `JLogStatus3xx` | status field with a 3xx value | `DiagnosticInfo` |
| `JLogStatus4xx` | status field with a 4xx value | `DiagnosticWarn` |
| `JLogStatus5xx` | status field with a 5xx value | `DiagnosticError` |
| `JLogBadge*` | derived on first use: a color group's color reversed and bold, for `inverted` and `pill` fields (e.g. `JLogBadgeJLogStatus2xx`) | none; redefined on `ColorScheme` |
| `JLogMessage` | message text | `Normal` |
| `JLogKey` | `key=` in compact, object keys in expanded, when `view.field_colors = false` | `Identifier` |
| `JLogField1` … `JLogField8` | keys and FIELDS names, one color per field in first-seen order, cycling | the first distinctly colored of `Identifier`, `Function`, `Type`, `Constant`, `Special`, `Statement`, `PreProc`, `Character`, `Label`, `Keyword`, `Tag`, `Directory`, skipping any colored like a value (`JLogValue`, `JLogString`, `JLogNumber`, `JLogBoolean`, `JLogNull`) |
| `JLogValue` | compact values | `String` |
| `JLogString` | expanded string values | `String` |
| `JLogNumber` | expanded number values | `Number` |
| `JLogBoolean` | expanded boolean values | `Boolean` |
| `JLogNull` | expanded null values | `Constant` |
| `JLogPrefix` | text before embedded JSON | `Comment` |
| `JLogPlain` | non-JSON entries and continuation lines | `Comment` |
| `JLogGroupHeader` | group headers (virtual lines and closed group folds) | `Title` |
| `JLogSectionHeader` | sidebar `FILTERS` / `GROUP BY` / `FIELDS` | `Title` |
| `JLogFieldName` | field names in the FIELDS section, when `view.field_colors = false` | `Identifier` |
| `JLogFieldCount` | counts in the FIELDS section | `Comment` |
| `JLogFieldStale` | FIELDS counts kept from the last apply while new ones are counted | `NonText` |
| `JLogHint` | sidebar examples on empty FILTERS / GROUP BY lines and `:w to apply` | `Comment` |
| `JLogWinbar` | jlog winbar text | `WinBar` |
| `JLogOverlap` | entries a page shares with its neighbours | `Comment` |

## Benchmark

jlog is compared against `jq` and `vim.json.decode` on 10k to 500k line files; see
[bench/results.md](bench/results.md). `make bench` regenerates it (jq is needed for the comparison rows).
