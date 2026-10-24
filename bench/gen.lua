-- Deterministic slog-shaped log generator shared by tests/perf.test.lua and bench/run.lua.
local M = {}

local PATHS = { "/api/licence-checks", "/api/users", "/api/vehicles", "/healthz", "/api/orders", "/api/quotes" }
local LEVELS = { "INFO", "INFO", "INFO", "WARN", "ERROR" }
local STATUSES = { 200, 200, 201, 204, 400, 404, 500, 502 }

---@param index integer
---@return string
local function json_line(index)
  local status = STATUSES[index % #STATUSES + 1]
  local line = string.format(
    '{"time":"2026-10-22T10:%02d:%02d.%03dZ","level":"%s","msg":"request completed","service":"user-api",'
      .. '"request_id":"req-%08d","method":"GET","path":"%s","status":%d,"latency_ms":%d.%d,"bytes":%d',
    math.floor(index / 60000) % 60,
    math.floor(index / 1000) % 60,
    index % 1000,
    LEVELS[index % #LEVELS + 1],
    math.floor(index / 3),
    PATHS[index % #PATHS + 1],
    status,
    index % 97,
    index % 10,
    index * 7 % 5000
  )

  if index % 7 == 0 then
    -- double-encoded error document stored as a string
    line = line
      .. string.format(
        ',"err":"{\\"code\\":%d,\\"detail\\":\\"upstream timeout after %dms\\",\\"retry\\":true}"',
        status,
        index % 900
      )
  end

  return line .. "}"
end

-- method, status and request body per verb; a PATCH body is a JSON Patch array
local REQUESTS = {
  { "GET", 200, '{"query":{"page":%d,"filter":{"state":"open","tags":["eu","b2b"]}}}' },
  { "POST", 201, '{"item":{"sku":"SKU-%05d","qty":3,"price":{"amount":129.95,"currency":"EUR"}}}' },
  { "PUT", 200, '{"order":{"id":%d,"state":"confirmed","shipping":{"carrier":"dhl","address":{"city":"Berlin"}}}}' },
  { "PATCH", 200, '[{"op":"replace","path":"/state","value":"shipped"},{"op":"add","path":"/notes/-","value":"%d"}]' },
  { "DELETE", 204, "null" },
}

---An access log line with nested request, response, user and trace objects.
---@param index integer
---@return string
local function nested_json_line(index)
  local request = REQUESTS[index % #REQUESTS + 1]
  -- every 13th request fails whatever its verb
  local status = index % 13 == 0 and 500 or request[2]
  local line = string.format(
    '{"time":"2026-10-22T10:%02d:%02d.%03dZ","level":"%s","msg":"request completed","service":"order-api",'
      .. '"request_id":"req-%08d","http":{"method":"%s","path":"/api/orders/%d","status":%d,"latency_ms":%d.%d,'
      .. '"request":{"headers":{"content-type":"application/json","user-agent":"order-client/2.%d"},"body":%s},'
      .. '"response":{"bytes":%d,"headers":{"x-trace-id":"tr-%06x"}}},'
      .. '"user":{"id":"u-%d","roles":["%s","viewer"],"org":{"id":"org-%d","plan":"%s"}},'
      .. '"trace":{"span_id":"sp-%06x","parent":{"span_id":"sp-%06x","service":"gateway"}}',
    math.floor(index / 60000) % 60,
    math.floor(index / 1000) % 60,
    index % 1000,
    status == 500 and "ERROR" or "INFO",
    math.floor(index / 3),
    request[1],
    index % 5000,
    status,
    index % 97,
    index % 10,
    index % 9,
    string.format(request[3], index % 500),
    index * 7 % 5000,
    index,
    index % 400,
    index % 3 == 0 and "admin" or "ops",
    index % 40,
    index % 2 == 0 and "pro" or "free",
    index * 3,
    index * 3 + 1
  )

  if status == 500 then
    -- double-encoded error document stored as a string
    line = line
      .. string.format(
        ',"err":"{\\"code\\":500,\\"detail\\":\\"upstream timeout after %dms\\",\\"retry\\":true}"',
        index % 900
      )
  end

  return line .. "}"
end

---@param count integer
---@param pure boolean|nil
---@param make_line fun(index: integer): string
---@return string[]
local function lines_of(count, pure, make_line)
  local lines = {}

  for index = 1, count do
    lines[#lines + 1] = (not pure and index % 10 == 0 and "2026-10-22T10:00:00Z " or "") .. make_line(index)
    if not pure and index % 50 == 0 then
      lines[#lines + 1] = "goroutine 1 [running]:"
      lines[#lines + 1] = "main.handle(0xc000123456)"
    end
  end

  return lines
end

---JSONL lines: every 10th has a text prefix, every 50th is followed by stack-trace continuation lines.
---@param count integer number of entries
---@param pure boolean|nil only bare JSON lines (what jq and `vim.json.decode` per line can read)
---@return string[]
M.jsonl_lines = function(count, pure)
  return lines_of(count, pure, json_line)
end

---Like `jsonl_lines`, with nested objects and GET, POST, PUT, PATCH and DELETE requests.
---@param count integer number of entries
---@param pure boolean|nil only bare JSON lines
---@return string[]
M.nested_lines = function(count, pure)
  return lines_of(count, pure, nested_json_line)
end

---Loki export (JSON array of {line, timestamp, fields}); `line` is a JSON log, every 10th a plain text line.
---@param count integer
---@param newest_first boolean|nil list the newest element first, as Grafana exports do
---@return string
M.loki_text = function(count, newest_first)
  local items = {}

  for index = 1, count do
    items[newest_first and count - index + 1 or index] = {
      line = index % 10 == 0 and "redis: connection pool: unhealthy\n" or json_line(index),
      -- a string: past 2^53 a Lua number would lose the nanoseconds
      timestamp = "1792157405" .. string.format("%09d", index * 1000),
      fields = { app = "user-api", env = "uat", pod = "user-api-" .. index % 5 },
    }
  end

  return vim.json.encode(items)
end

return M
