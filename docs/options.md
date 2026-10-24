# Configuration Options

Full reference for all options accepted by `require("jlog").setup()`. All options are optional; omitted keys fall back to the defaults shown below.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `fields.time` | `string[]` | `{ "time", "ts", "timestamp", "@timestamp" }` | Keys tried in order for the `time` field. |
| `fields.level` | `string[]` | `{ "level", "lvl", "severity" }` | Keys tried in order for the `level` field. |
| `fields.message` | `string[]` | `{ "msg", "message" }` | Keys tried in order for the `msg` field. |
| `fields.status` | `string[]` | `{ "status", "status_code" }` | Keys of the status-code field, class-colored (`JLogStatus2xx`..`JLogStatus5xx`) in compact lines when its style is `inverted` or `pill`, e.g. `compact.fields.status = { style = "inverted" }`; a plain status field keeps its key color. |
| `compact.style` | `JLogFieldStyle` | `"plain"` | Default style of compact fields: `"plain"` (`key=value`), `"inverted"` (value as a colored block) or `"pill"` (inverted with caps). `level` defaults to `"inverted"` and this overrides it when not `"plain"`; it never applies to `time` or `message`. |
| `compact.order` | `string[]` | `{}` | Top-level keys shown first in compact lines, in this order. Dotted names are ignored; `time`, `level`, `message` and `status` match their role whatever the key is called; unlisted role fields stay at the front. |
| `compact.fields` | `table<string, JLogCompactField>` | `{}` | Per field key or role (`time`, `level`, `message`, `status`) overrides; a key's entry wins over its role's. |
| `compact.fields[...].style` | `JLogFieldStyle` | `compact.style`; `time`/`message` stay `plain`, `level` is `inverted` under a `plain` global | Style of that field. |
| `compact.fields[...].format` | `fun(ctx): string, string\|nil` | none | Returns the field's text and optionally a highlight group. `ctx` has `value`, `key`, `entry`; it is reused, do not keep it, and `ctx.entry` is read-only. An invalid group name is ignored with a warning. Errors or a non-string return fall back to the default text and warn once per field. Runs on every rendered line. |
| `compact.pill.left` | `string` | `"\u{e0b6}"` | Left cap of `pill` fields, drawn as inline virtual text. Needs a Nerd Font; `""` gives a square end. |
| `compact.pill.right` | `string` | `"\u{e0b4}"` | Right cap of `pill` fields. Needs a Nerd Font; `""` gives a square end. |
| `view.mode` | `JLogViewMode` | `"compact"` | Initial view: `"compact"` (one line per entry) or `"expanded"` (indented JSON). |
| `view.sort` | `JLogSort` | `"desc"` | Initial order: `"asc"` (oldest first) or `"desc"` (newest first). |
| `view.field_colors` | `boolean` | `true` | Color each field's keys in the log view and its FIELDS name alike, cycling through `JLogField1`…`JLogField8` in first-seen order. A key never takes a value's color, and the cycle uses only distinct colors from the colorscheme. `false` uses `JLogKey` and `JLogFieldName`. |
| `unwrap.enable` | `boolean` | `true` | Unwrap double-encoded JSON inside string values. |
| `unwrap.max_depth` | `integer` | `4` | Maximum levels of nested unwrapping. |
| `sidebar.width` | `integer` | `40` | Sidebar width in columns. |
| `sidebar.position` | `JLogSidebarPosition` | `"right"` | Sidebar side: `"left"` or `"right"`. |
| `facets.top_values` | `integer` | `10` | Number of top values listed per field in the sidebar. |
| `paging.size` | `integer` | `100000` | Page size: source lines for JSONL, array elements for JSON arrays and timestamped exports. A JSONL page boundary moves on up to `size / 10` lines to the next line that starts an entry, so an entry does not split; a longer run of plain lines is split there. |
| `paging.overlap` | `integer` | `2000` | How much of each neighbouring page is also shown on a page, so a request at a page edge stays whole: source lines for JSONL (extended so an entry is never cut), elements for JSON arrays and timestamped exports. |
| `progress` | `JLogProgress` | `"auto"` | How long-running work (loading, indexing, applying, rendering) reports: `"auto"` sends progress messages on Neovim 0.12+, which UIs that draw progress show with a spinner, and uses `vim.notify` on older versions; `"notify"` always uses `vim.notify`. |
| `keymaps.toggle_entry` | `string\|false` | `"<Tab>"` | Expand/collapse the entry under the cursor. |
| `keymaps.toggle_mode` | `string\|false` | `"E"` | Toggle compact/expanded for the whole view. |
| `keymaps.raw` | `string\|false` | `"gf"` | Show the entry's raw text in a float; inside the float, jump to the source line (JSONL only). |
| `keymaps.reverse` | `string\|false` | `"R"` | Reverse order. |
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
