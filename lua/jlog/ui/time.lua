---@class JLogTime
---@field value string the time as written in the log; a Loki timestamp in nanoseconds
---@field seconds integer|nil seconds since the epoch, UTC; nil when the value is not a time jlog can read
---@field millis string|nil three digits of milliseconds; nil with `seconds`

local M = {}

-- stands in for `%L` while `os.date` formats the rest, then becomes the milliseconds
local MILLIS_MARK = "\1"

-- the last second formatted: logs are mostly in order, so neighbouring lines share it
local cache_key, cache_text
-- one table refilled per call of a `time_format` function
local time_ctx = {}
-- a failing `time_format` function warns once, then shows the values as written
local warned = false

---Days from 1970-01-01 to a proleptic Gregorian date, without `os.time` and its local timezone.
---@param year integer
---@param month integer
---@param day integer
---@return integer
local function days_from_civil(year, month, day)
  local era, year_of_era, day_of_year, day_of_era

  year = month <= 2 and year - 1 or year
  era = math.floor(year / 400)
  year_of_era = year - era * 400
  day_of_year = math.floor((153 * (month + (month > 2 and -3 or 9)) + 2) / 5) + day - 1
  day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year

  return era * 146097 + day_of_era - 719468
end

---Seconds east of UTC for an ISO 8601 zone suffix; none or `Z` is UTC.
---@param zone string
---@return integer|nil nil when the suffix is not a zone
local function zone_offset(zone)
  local sign, hours, minutes

  if zone == "" or zone == "Z" or zone == "z" then
    return 0
  end
  sign, hours, minutes = zone:match("^([+-])(%d%d):?(%d%d)$")
  if not sign then
    return nil
  end

  return (sign == "-" and -1 or 1) * (tonumber(hours) * 3600 + tonumber(minutes) * 60)
end

---Call a `time_format` function; one that errors or returns no string shows `value`.
---@param format fun(time: JLogTime): string
---@param value string
---@param seconds integer|nil
---@param millis string|nil
---@return string
local function call_format(format, value, seconds, millis)
  local ok, text

  time_ctx.value, time_ctx.seconds, time_ctx.millis = value, seconds, millis
  ok, text = pcall(format, time_ctx)
  if ok and type(text) == "string" then
    return text
  end
  if not warned then
    warned = true
    vim.notify(
      ("jlog: view.time_format failed: %s"):format(ok and "it did not return a string" or tostring(text)),
      vim.log.levels.WARN
    )
  end

  return value
end

---Format an epoch time with `view.time_format`, in local time or UTC by `view.time_utc`.
---@param seconds integer seconds since the epoch, UTC
---@param millis string three digits
---@param view JLogViewOptions
---@param value string the time as written, for a `time_format` function
---@return string
M.format_epoch = function(seconds, millis, view, value)
  local zone = view.time_utc and "!" or ""
  local key, format

  if type(view.time_format) == "function" then
    return call_format(view.time_format, value, seconds, millis)
  end
  key = zone .. seconds .. " " .. view.time_format
  if key ~= cache_key then
    format = view.time_format:gsub("%%L", MILLIS_MARK)
    cache_key, cache_text = key, os.date(zone .. format, seconds)
  end

  return (cache_text:gsub(MILLIS_MARK, millis))
end

---Format an ISO 8601 date-time with `view.time_format`; a function is called for any value.
---@param value string
---@param view JLogViewOptions
---@return string|nil nil when `value` is not an ISO 8601 date-time and the format is a string
M.format_iso = function(value, view)
  local year, month, day, hour, minute, second, fraction, zone =
    value:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)%.?(%d*)(.*)$")
  local offset = zone and zone_offset(zone)
  local seconds = offset
    and days_from_civil(tonumber(year), tonumber(month), tonumber(day)) * 86400
      + tonumber(hour) * 3600
      + tonumber(minute) * 60
      + tonumber(second)
      - offset
  local millis = offset and (fraction .. "000"):sub(1, 3)

  if type(view.time_format) == "function" then
    return call_format(view.time_format, value, seconds or nil, millis or nil)
  end
  if not seconds then
    return nil
  end

  return M.format_epoch(seconds, millis, view, value)
end

return M
