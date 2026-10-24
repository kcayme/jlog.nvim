local filter = require("jlog.query.filter")
local highlights = require("jlog.ui.highlights")

local M = {}

local ROLES = { "time", "level", "message", "status" }

-- weak cache: field names whose format already warned, per `opts` table
local failed_by_opts = setmetatable({}, { __mode = "k" })
-- one context table refilled per format call
local format_ctx = {}

---The role whose keys in `opts.fields` include `name`, if any.
---@param opts JLogOptions
---@param name string
---@return "time"|"level"|"message"|"status"|nil
local function role_of(opts, name)
  for _, role in ipairs(ROLES) do
    if vim.tbl_contains(opts.fields[role], name) then
      return role
    end
  end

  return nil
end

---@param opts JLogOptions
---@param name string
---@param err any
local function warn_once(opts, name, err)
  local failed = failed_by_opts[opts] or {}

  failed_by_opts[opts] = failed
  if failed[name] then
    return
  end
  failed[name] = true
  vim.notify(("jlog: sidebar format for %s failed: %s"):format(name, tostring(err)), vim.log.levels.WARN)
end

---The text and highlight group `format` gives for `name`, or nil when it fails (it warns once per field).
---@param opts JLogOptions
---@param format fun(ctx: JLogSidebarFormatContext): string, string|nil
---@param name string
---@param distinct integer
---@return string|nil text
---@return string|nil group
local function run_format(opts, format, name, distinct)
  local ok, text, group

  format_ctx.name, format_ctx.distinct = name, distinct
  ok, text, group = pcall(format, format_ctx)
  if not ok then
    warn_once(opts, name, text)

    return nil
  end
  if type(text) ~= "string" then
    warn_once(opts, name, "expected a string, got " .. type(text))

    return nil
  end
  if type(group) == "string" and not (group:match("^[%w_.@-]+$") and #group <= 200) then
    warn_once(opts, name, "invalid highlight group " .. group)
    group = nil
  end

  return text, type(group) == "string" and group or nil
end

---How the sidebar shows field `name` in FIELDS: its text, its highlight group, and a pill's cap group.
---@param opts JLogOptions
---@param name string field path as FIELDS lists it
---@param distinct integer distinct values counted for the field
---@return string text one line: the name escaped as FIELDS shows it, or format's text with newlines escaped
---@return string group
---@return string|nil cap_group set when the name is drawn as a pill
M.of = function(opts, name, distinct)
  local sidebar = opts.sidebar
  local role = role_of(opts, name)
  local by_name = sidebar.fields[name]
  local by_role = role and sidebar.fields[role]
  local style = (by_name and by_name.style) or (by_role and by_role.style) or sidebar.style
  local format = (by_name and by_name.format) or (by_role and by_role.format)
  local color = sidebar.field_colors and highlights.field_group(name) or "JLogFieldName"
  local text, group

  if format then
    text, group = run_format(opts, format, name, distinct)
  end
  color = group or color
  text = text and (text:gsub("\n", "\\n")) or filter.escape_field(name)
  if style == "plain" then
    return text, color
  end

  return text, highlights.badge_of(color), style == "pill" and color or nil
end

return M
