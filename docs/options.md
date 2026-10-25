# Configuration Options

Full reference for all options accepted by `require("jlog").setup()`. All options are optional; omitted keys fall back to the defaults shown below.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `fields.time` | `string[]` | `{ "time", "ts", "timestamp", "@timestamp" }` | Keys tried in order for the `time` field. |
| `fields.level` | `string[]` | `{ "level", "lvl", "severity" }` | Keys tried in order for the `level` field. |
| `fields.message` | `string[]` | `{ "msg", "message" }` | Keys tried in order for the `msg` field. |
| `fields.status` | `string[]` | `{ "status", "status_code" }` | Keys of the status-code field, class-colored (`JLogStatus2xx`..`JLogStatus5xx`) in compact lines when its style is `inverted` or `pill`, e.g. `compact.fields.status = { style = "inverted" }`; a plain status field keeps its key color. |
| `compact.style` | `JLogFieldStyle` | `"plain"` | Default style of compact fields: `"plain"` (`key=value`), `"inverted"` (`key=value` with the key as a colored block) or `"pill"` (inverted with caps); fields in `compact.style_values` are styled on the value instead. `level` defaults to `"inverted"` and this overrides it when not `"plain"`; it never applies to `time` or `message`. |
| `compact.order` | `string[]` | `{}` | Top-level keys shown first in compact lines, in this order. Dotted names are ignored; `time`, `level`, `message` and `status` match their role whatever the key is called; unlisted role fields stay at the front. |
| `compact.fields` | `table<string, JLogCompactField>` | `{}` | Per field key or role (`time`, `level`, `message`, `status`) overrides; a key's entry wins over its role's. |
| `compact.fields[...].style` | `JLogFieldStyle` | `compact.style`; `time`/`message` stay `plain`, `level` is `inverted` under a `plain` global | Style of that field. |
| `compact.fields[...].format` | `fun(ctx): string, string\|nil` | none | Returns the field's text and optionally a highlight group. `ctx` has `value`, `key`, `entry`; it is reused, do not keep it, and `ctx.entry` is read-only. An invalid group name is ignored with a warning. Errors or a non-string return fall back to the default text and warn once per field. Runs on every rendered line. |
| `compact.style_values` | `string[]` | `{ "level", "status" }` | Keys or roles whose value, not key, takes an `inverted` or `pill` style, shown without the key. Remove one to give it a styled key followed by its value. `time` and `message` are always styled on the value. |
| `compact.pill.left` | `string` | `"\u{e0b6}"` | Left cap of `pill` fields, drawn as inline virtual text. Needs a Nerd Font; `""` gives a square end. |
| `compact.pill.right` | `string` | `"\u{e0b4}"` | Right cap of `pill` fields. Needs a Nerd Font; `""` gives a square end. |
| `view.mode` | `JLogViewMode` | `"compact"` | Initial view: `"compact"` (one line per entry) or `"expanded"` (indented JSON). |
| `view.sort` | `JLogSort` | `"desc"` | Initial order: `"asc"` (oldest first) or `"desc"` (newest first). |
| `view.field_colors` | `boolean` | `true` | Color each field's keys in the log view, cycling through `JLogField1`…`JLogField8` in first-seen order; a field keeps the same color in FIELDS when `sidebar.fields.colors` is on. A key never takes a value's color, and the cycle uses only distinct colors from the colorscheme. `false` uses `JLogKey`. |
| `unwrap.enable` | `boolean` | `true` | Unwrap double-encoded JSON inside string values. |
| `unwrap.max_depth` | `integer` | `4` | Maximum levels of nested unwrapping. |
| `sidebar.width` | `integer` | `45` | Sidebar width in columns. |
| `sidebar.position` | `JLogSidebarPosition` | `"right"` | Sidebar side: `"left"` or `"right"`. |
| `sidebar.sections` | `JLogSidebarSection[]` | `{ "filters", "group", "sort", "fields" }` | Sidebar sections in the order shown: `"filters"`, `"group"`, `"sort"`, `"fields"`. A section left out is hidden; `:w` then leaves its filters or group as the field actions and `:JLog` commands set them. `setup` warns about unknown or repeated names and drops them, and falls back to the default order with a warning when the value is not a list. |
| `sidebar.fields.pinned` | `string[]` | `{}` | Fields listed first in FIELDS, in this order: a field path as FIELDS shows it, or a role (`time`, `level`, `message`, `status`) standing for its keys in `fields`. Fields not in the log are skipped. |
| `sidebar.fields.sort` | `JLogFieldSort` | `"alphabetical"` | Order of the other fields: `"alphabetical"`, or `"count"` (in the most entries first, ties by name). A count sort is applied once the counts are final; while a file loads or a filter is counted, rows keep their place and new fields are added at the end. Labels of timestamped exports come after the other fields either way. |
| `sidebar.fields.colors` | `boolean` | `true` | Color each field name in FIELDS by field, in the same `JLogField1`…`JLogField8` color its keys get in the log view. `false` uses `JLogFieldName`. Independent of `view.field_colors`. |
| `sidebar.fields.style` | `JLogFieldStyle` | `"plain"` | Default style of field names in FIELDS: `"plain"` (colored text), `"inverted"` (the name as a colored block) or `"pill"` (inverted with caps). |
| `sidebar.fields.styles` | `table<string, JLogSidebarField>` | `{}` | Per field overrides for FIELDS names, keyed by the field path FIELDS shows (e.g. `req.method`) or a role (`time`, `level`, `message`, `status`); a path's entry wins over its role's. |
| `sidebar.fields.styles[...].style` | `JLogFieldStyle` | `sidebar.fields.style` | Style of that field's name. |
| `sidebar.fields.styles[...].format` | `fun(ctx): string, string\|nil` | none | Returns the name's text and optionally a highlight group. `ctx` has `name` (the field path) and `distinct` (distinct values counted); it is reused, do not keep it. Newlines in the text are shown as `\n`. Errors, a non-string return or an invalid group name fall back to the default and warn once per field. |
| `sidebar.fields.pill.left` | `string` | `"\u{e0b6}"` | Left cap of `pill` field names, drawn as inline virtual text. Needs a Nerd Font; `""` gives a square end. |
| `sidebar.fields.pill.right` | `string` | `"\u{e0b4}"` | Right cap of `pill` field names. Needs a Nerd Font; `""` gives a square end. |
| `facets.top_values` | `integer` | `10` | Number of top values listed per field in the sidebar. |
| `paging.size` | `integer` | `100000` | Page size: source lines for JSONL, array elements for JSON arrays and timestamped exports. A JSONL page boundary moves on up to `size / 10` lines to the next line that starts an entry, so an entry does not split; a longer run of plain lines is split there. |
| `paging.overlap` | `integer` | `2000` | How much of each neighbouring page is also shown on a page, so a request at a page edge stays whole: source lines for JSONL (extended so an entry is never cut), elements for JSON arrays and timestamped exports. |
| `progress` | `JLogProgress` | `"auto"` | How long-running work (loading, indexing, applying, rendering) reports: `"auto"` sends progress messages on Neovim 0.12+, which UIs that draw progress show with a spinner, and uses `vim.notify` on older versions; `"notify"` always uses `vim.notify`; `"off"` shows no progress messages. |
| `keymaps.toggle_entry` | `string\|false` | `"<Tab>"` | Expand/collapse the entry under the cursor. |
| `keymaps.toggle_mode` | `string\|false` | `"E"` | Toggle compact/expanded for the whole view. |
| `keymaps.raw` | `string\|false` | `"gf"` | Show the entry's raw text in a float; inside the float, jump to the source line (JSONL only). |
| `keymaps.reverse` | `string\|false` | `"R"` | Reverse order, in the log view and the sidebar; the sidebar's SORT line shows the key. |
| `keymaps.next_entry` | `string\|false` | `"]]"` | Next entry. |
| `keymaps.prev_entry` | `string\|false` | `"[["` | Previous entry. |
| `keymaps.next_error` | `string\|false` | `"]e"` | Next ERROR-level entry. |
| `keymaps.prev_error` | `string\|false` | `"[e"` | Previous ERROR-level entry. |
| `keymaps.next_page` | `string\|false` | `"]p"` | Next page of a paged log. |
| `keymaps.prev_page` | `string\|false` | `"[p"` | Previous page of a paged log. |
| `keymaps.focus_sidebar` | `string\|false` | `"s"` | Focus the sidebar. |
| `keymaps.toggle_sidebar` | `string\|false` | `"S"` | Show/hide the sidebar (in the log view and the sidebar). |
| `keymaps.close` | `string\|false` | `"q"` | Close the workspace (in the sidebar and log view). |
| `keymaps.add_filter` | `string\|false` | `"<CR>"` | Sidebar: add the field value under the cursor as a filter. |
| `keymaps.group_by` | `string\|false` | `"g"` | Sidebar: group by the field under the cursor. |
| `keymaps.help` | `string\|false` | `"?"` | Sidebar: open a guide to the keys; shown as `? help` on the sidebar's first line. |
