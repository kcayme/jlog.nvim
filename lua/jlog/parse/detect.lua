-- Detects the input format: Loki export, JSON array or JSONL.
local json = require("jlog.parse.json")

---@alias JLogFormat "loki"|"array"|"jsonl"

local M = {}

local HEAD_LIMIT = 65536
local SAMPLE_LINES = 20

---@param keys string[]
---@param opts JLogOptions
---@return boolean
local function has_log_key(keys, opts)
  local wanted = { opts.fields.time, opts.fields.level, opts.fields.message }

  for _, group in ipairs(wanted) do
    for _, key in ipairs(group) do
      if vim.tbl_contains(keys, key) then
        return true
      end
    end
  end

  return false
end

---@param line string
---@param opts JLogOptions
---@return boolean
local function is_log_line(line, opts)
  local _, decoded = json.object_at(line)

  return decoded ~= nil and has_log_key(vim.tbl_keys(decoded), opts)
end

---@param head string
---@param opts JLogOptions
---@return JLogFormat|nil
local function detect_array(head, opts)
  local start = head:find("{", 2, true)
  local node

  if not start then
    return nil
  end

  -- only the first element is parsed: the head may cut the array short
  node = json.parse(head, start)
  if not node or node.t ~= "object" then
    return nil
  end
  if vim.tbl_contains(node.keys, "line") and vim.tbl_contains(node.keys, "timestamp") then
    return "loki"
  end
  if has_log_key(node.keys, opts) then
    return "array"
  end

  return nil
end

---@param head string
---@param opts JLogOptions
---@return JLogFormat|nil
local function detect_jsonl(head, opts)
  local lines = vim.split(head, "\n", { plain = true })
  local sampled = 0
  local matched = 0

  -- shortcut: a head at the size limit is assumed cut mid-line; smaller heads are whole files
  if #head >= HEAD_LIMIT then
    table.remove(lines)
  end

  for _, line in ipairs(lines) do
    if sampled >= SAMPLE_LINES then
      break
    end
    if line:find("%S") then
      sampled = sampled + 1
      if is_log_line(line, opts) then
        matched = matched + 1
      end
    end
  end

  if sampled > 0 and matched * 2 >= sampled then
    return "jsonl"
  end

  return nil
end

---@param head string first <=64KB of the file
---@param opts JLogOptions
---@return JLogFormat|nil
M.detect = function(head, opts)
  local text = head:gsub("\r", "")

  -- `[INFO] {...}` lines are jsonl with a prefix: only `[` followed by an object (or `]`) is an array
  if text:match("^%s*%[%s*[{%]]") then
    return detect_array(text:gsub("^%s*", ""), opts)
  end

  return detect_jsonl(text, opts)
end

return M
