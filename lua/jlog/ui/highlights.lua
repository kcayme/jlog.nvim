local M = {}

---@class JLogHighlightGroup
---@field name string highlight group name
---@field link string group it links to by default; a badge takes its color from it instead
---@field badge boolean|nil drawn reversed: the link's color as the background

---Highlight groups and their default links, in definition order.
---@type JLogHighlightGroup[]
M.GROUPS = {
  { name = "JLogTime", link = "Comment" },
  { name = "JLogLevelError", badge = true, link = "DiagnosticError" },
  { name = "JLogLevelWarn", badge = true, link = "DiagnosticWarn" },
  { name = "JLogLevelInfo", badge = true, link = "DiagnosticInfo" },
  { name = "JLogLevelDebug", badge = true, link = "DiagnosticHint" },
  { name = "JLogLevelTrace", badge = true, link = "Comment" },
  { name = "JLogMessage", link = "Normal" },
  { name = "JLogKey", link = "Identifier" },
  { name = "JLogValue", link = "String" },
  { name = "JLogString", link = "String" },
  { name = "JLogNumber", link = "Number" },
  { name = "JLogBoolean", link = "Boolean" },
  { name = "JLogNull", link = "Constant" },
  { name = "JLogPrefix", link = "Comment" },
  { name = "JLogPlain", link = "Comment" },
  { name = "JLogGroupHeader", link = "Title" },
  { name = "JLogSectionHeader", link = "Title" },
  { name = "JLogFieldName", link = "Identifier" },
  { name = "JLogFieldCount", link = "Comment" },
  { name = "JLogFieldStale", link = "NonText" },
  { name = "JLogFieldIgnored", link = "NonText" },
  { name = "JLogHint", link = "Comment" },
  { name = "JLogWinbar", link = "WinBar" },
  { name = "JLogOverlap", link = "Comment" },
  { name = "JLogStatus2xx", link = "DiagnosticOk" },
  { name = "JLogStatus3xx", link = "DiagnosticInfo" },
  { name = "JLogStatus4xx", link = "DiagnosticWarn" },
  { name = "JLogStatus5xx", link = "DiagnosticError" },
}

M.FIELD_COLORS = 8

-- candidate links for the `JLogField*` key colors, in order of preference
local FIELD_LINKS = {
  "Identifier",
  "Function",
  "Type",
  "Constant",
  "Special",
  "Statement",
  "PreProc",
  "Character",
  "Label",
  "Keyword",
  "Tag",
  "Directory",
}
-- a key must never look like a value
local VALUE_GROUPS = { "JLogValue", "JLogString", "JLogNumber", "JLogBoolean", "JLogNull" }

---@type table<string, string> field path -> its `JLogField*` group, for the whole session
local field_groups = {}
local field_count = 0
---@type table<string, string> color group -> its badge group, cleared by setup so a colorscheme change rebuilds them
local badge_groups = {}
---@type table<string, string> badge group -> its cap group, cleared by setup like `badge_groups`
local cap_groups = {}

---The badge style of the color group `name`, or nil when it has no color to reverse.
---@param name string
---@return vim.api.keyset.highlight|nil
local function badge(name)
  local colors = vim.api.nvim_get_hl(0, { name = name, link = false })

  if not colors.fg and not colors.ctermfg then
    return nil
  end

  return { fg = colors.fg, ctermfg = colors.ctermfg, reverse = true, bold = true, default = true }
end

---The group drawing `color_group`'s color reversed and bold, defined on first use.
---@param color_group string
---@return string
M.badge_of = function(color_group)
  local name = badge_groups[color_group]

  if name then
    return name
  end
  name = "JLogBadge" .. color_group
  vim.api.nvim_set_hl(0, name, badge(color_group) or { reverse = true, bold = true, default = true })
  badge_groups[color_group] = name

  return name
end

---The fg-only group drawing a pill's caps in the color `group` shows as its background, defined on first use.
---@param group string
---@return string
M.cap_of = function(group)
  local name = cap_groups[group]
  local colors, fg, ctermfg

  if name then
    return name
  end
  name = "JLogCap" .. group
  colors = vim.api.nvim_get_hl(0, { name = group, link = false })
  fg = colors.reverse and colors.fg or colors.bg or colors.fg
  ctermfg = colors.reverse and colors.ctermfg or colors.ctermbg or colors.ctermfg
  if fg or ctermfg then
    vim.api.nvim_set_hl(0, name, { fg = fg, ctermfg = ctermfg })
  else
    vim.api.nvim_set_hl(0, name, { link = M.link_of(group) or group })
  end
  cap_groups[group] = name

  return name
end

---The default link of the group `name` in `M.GROUPS`.
---@param name string
---@return string|nil
M.link_of = function(name)
  for _, group in ipairs(M.GROUPS) do
    if group.name == name then
      return group.link
    end
  end
end

---The color group of field `name`: the next `JLogField*` group the first time it is seen, cycling after the last.
---@param name string dotted field path
---@return string
M.field_group = function(name)
  local group = field_groups[name]

  if group then
    return group
  end
  group = "JLogField" .. (field_count % M.FIELD_COLORS + 1)
  field_count = field_count + 1
  field_groups[name] = group

  return group
end

---The color `name` is drawn in: its gui color, else its terminal color.
---@param name string
---@return string
local function color_of(name)
  local colors = vim.api.nvim_get_hl(0, { name = name, link = false })

  return colors.fg and ("gui" .. colors.fg) or colors.ctermfg and ("cterm" .. colors.ctermfg) or "none"
end

---Field key links in distinct colors that no value group uses; all candidates when none qualify.
---@return string[]
local function field_links()
  local taken = {}
  local links = {}
  local color

  for _, name in ipairs(VALUE_GROUPS) do
    taken[color_of(name)] = true
  end
  for _, link in ipairs(FIELD_LINKS) do
    color = color_of(link)
    if not taken[color] then
      taken[color] = true
      links[#links + 1] = link
    end
  end

  return #links > 0 and links or FIELD_LINKS
end

---Define every `JLog*` group by default only, so user and colorscheme definitions win.
M.setup = function()
  local links

  badge_groups, cap_groups = {}, {}
  for _, group in ipairs(M.GROUPS) do
    vim.api.nvim_set_hl(0, group.name, group.badge and badge(group.link) or { link = group.link, default = true })
  end
  -- picked after the value groups exist, so their colors are known
  links = field_links()
  for index = 1, M.FIELD_COLORS do
    vim.api.nvim_set_hl(0, "JLogField" .. index, { link = links[(index - 1) % #links + 1], default = true })
  end
end

return M
