# Configuration Options

Full reference for all options accepted by `require("jlog").setup()`. All options are optional; omitted keys fall back to the defaults shown below.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `fields.time` | `string[]` | `{ "time", "ts", "timestamp", "@timestamp" }` | Keys tried in order for the `time` field. |
| `fields.level` | `string[]` | `{ "level", "lvl", "severity" }` | Keys tried in order for the `level` field. |
| `fields.message` | `string[]` | `{ "msg", "message" }` | Keys tried in order for the `msg` field. |
| `view.mode` | `JLogViewMode` | `"compact"` | Initial view: `"compact"` (one line per entry) or `"expanded"` (indented JSON). |
| `view.sort` | `JLogSort` | `"desc"` | Initial order: `"asc"` (oldest first) or `"desc"` (newest first). |
| `unwrap.enable` | `boolean` | `true` | Unwrap double-encoded JSON inside string values. |
| `unwrap.max_depth` | `integer` | `4` | Maximum levels of nested unwrapping. |
| `sidebar.width` | `integer` | `40` | Sidebar width in columns. |
| `sidebar.position` | `JLogSidebarPosition` | `"right"` | Sidebar side: `"left"` or `"right"`. |
| `facets.top_values` | `integer` | `10` | Number of top values listed per field in the sidebar. |
| `paging.size` | `integer` | `100000` | Page size: source lines for JSONL, array elements for JSON arrays and Loki exports. A JSONL page boundary moves on up to `size / 10` lines to the next line that starts an entry, so an entry does not split; a longer run of plain lines is split there. |
| `paging.overlap` | `integer` | `2000` | How much of each neighbouring page is also shown on a page, so a request at a page edge stays whole: source lines for JSONL (extended so an entry is never cut), elements for JSON arrays and Loki exports. |
| `keymaps.toggle_entry` | `string\|false` | `"<Tab>"` | Expand/collapse the entry under the cursor. |
| `keymaps.toggle_mode` | `string\|false` | `"E"` | Toggle compact/expanded for the whole view. |
| `keymaps.raw` | `string\|false` | `"gf"` | Show the entry's raw text in a float; inside the float, jump to the source line (JSONL only). |
| `keymaps.reverse` | `string\|false` | `"R"` | Reverse order. |
| `keymaps.next_entry` | `string\|false` | `"]]"` | Next entry. |
| `keymaps.prev_entry` | `string\|false` | `"[["` | Previous entry. |
| `keymaps.next_error` | `string\|false` | `"]e"` | Next ERROR-level entry. |
| `keymaps.prev_error` | `string\|false` | `"[e"` | Previous ERROR-level entry. |
| `keymaps.focus_sidebar` | `string\|false` | `"s"` | Focus the sidebar. |
| `keymaps.toggle_sidebar` | `string\|false` | `"S"` | Show/hide the sidebar. |
| `keymaps.close` | `string\|false` | `"q"` | Close the workspace (in the sidebar and log view). |
| `keymaps.add_filter` | `string\|false` | `"<CR>"` | Sidebar: add the field value under the cursor as a filter. |
| `keymaps.group_by` | `string\|false` | `"g"` | Sidebar: group by the field under the cursor. |
