local M = {}

-- stands in for `%L` while `os.date` formats the rest, then becomes the milliseconds
local MILLIS_MARK = "\1"

-- the last second formatted: logs are mostly in order, so neighbouring lines share it
local cache_key, cache_text

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

---Format an epoch time with `view.time_format`, in local time or UTC by `view.time_utc`.
---@param seconds integer seconds since the epoch, UTC
---@param millis string three digits
---@param view JLogViewOptions
---@return string
M.format_epoch = function(seconds, millis, view)
  local zone = view.time_utc and "!" or ""
  local key = zone .. seconds .. " " .. view.time_format
  local format

  if key ~= cache_key then
    format = view.time_format:gsub("%%L", MILLIS_MARK)
    cache_key, cache_text = key, os.date(zone .. format, seconds)
  end

  return (cache_text:gsub(MILLIS_MARK, millis))
end

---Format an ISO 8601 date-time with `view.time_format`.
---@param value string
---@param view JLogViewOptions
---@return string|nil nil when `value` is not an ISO 8601 date-time
M.format_iso = function(value, view)
  local year, month, day, hour, minute, second, fraction, zone =
    value:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)%.?(%d*)(.*)$")
  local offset = zone and zone_offset(zone)

  if not offset then
    return nil
  end

  return M.format_epoch(
    days_from_civil(tonumber(year), tonumber(month), tonumber(day)) * 86400
      + tonumber(hour) * 3600
      + tonumber(minute) * 60
      + tonumber(second)
      - offset,
    (fraction .. "000"):sub(1, 3),
    view
  )
end

return M
