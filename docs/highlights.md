# Highlight Groups

Every highlight group jlog draws with, what it colors and its default.

## Overriding

All groups are defined with `default = true`, so a definition of your own wins whether it is set before or after jlog
loads, and jlog re-applies its defaults on `ColorScheme`. Override them with
`vim.api.nvim_set_hl(0, "JLogLevelError", { ... })` or `:hi`. Level groups are badges: the linked group's color,
reversed and bold, so the level reads as a colored label in compact lines.

`:colorscheme` clears every highlight, your own overrides included; to keep them across theme changes, set them in a
`ColorScheme` autocmd:

```lua
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    vim.api.nvim_set_hl(0, "JLogPageCurrent", { fg = "#ffffff", bold = true })
  end,
})
```

## Groups

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
| `JLogCap*` | derived on first use: a pill's end caps (`compact.pill` / `sidebar.fields.pill` glyphs), drawn in the color its badge shows as background (e.g. `JLogCapJLogBadgeJLogStatus2xx`); restyle the pill's color group rather than these | none; redefined on `ColorScheme` |
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
| `JLogSectionHeader` | sidebar `FILTERS` / `GROUP BY` / `LIMIT` / `SORT` / `FIELDS` | `Title` |
| `JLogFieldName` | field names in the FIELDS section, when `sidebar.fields.colors = false` | `Identifier` |
| `JLogFieldCount` | counts in the FIELDS section | `Comment` |
| `JLogFieldStale` | FIELDS counts kept from the last apply while new ones are counted | `NonText` |
| `JLogFieldIgnored` | FIELDS names of fields hidden from compact lines | `NonText` |
| `JLogFilterInvalid` | The "invalid filter" note beside FILTERS while a filter line fails to parse | `DiagnosticWarn` |
| `JLogHint` | sidebar examples on empty FILTERS / GROUP BY / LIMIT lines, `:w to apply`, and the SORT order | `Comment` |
| `JLogWinbar` | jlog winbar text | `WinBar` |
| `JLogOverlap` | entries a page shares with its neighbours | `Comment` |
| `JLogPageCurrent` | the page shown, beside the sidebar's PAGE and in its per-page counts | `Normal` |
