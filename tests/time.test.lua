local time = require("jlog.parse.time")

describe("time", function()
  local utc = { time_format = "%Y-%m-%d %H:%M:%S.%L", time_utc = true }

  it("should format an ISO time in UTC with milliseconds", function()
    assert.are.equal("2026-10-16 12:50:24.970", time.format_iso("2026-10-16T12:50:24.970389138Z", utc))
  end)

  it("should apply the zone offset and pad the fraction", function()
    assert.are.equal("2026-10-16 10:50:24.900", time.format_iso("2026-10-16T12:50:24.9+02:00", utc))
    assert.are.equal("2026-10-17 01:20:24.000", time.format_iso("2026-10-16T23:50:24-0130", utc))
    assert.are.equal("2024-02-29 00:00:00.000", time.format_iso("2024-02-29 00:00:00", utc))
  end)

  it("should return nil when the value is not an ISO date-time", function()
    assert.is_nil(time.format_iso("12:50:24", utc))
    assert.is_nil(time.format_iso("2026-10-16T12:50:24 PST", utc))
  end)

  it("should show local time unless time_utc is set", function()
    local view = { time_format = "%H:%M", time_utc = false }

    assert.are.equal(os.date("%H:%M", 1760619024), time.format_iso("2026-10-16T12:50:24Z", view))
  end)

  it("should call a time_format function with the value as written and the parsed epoch", function()
    local seen
    local view = {
      time_format = function(t)
        seen = { t.value, t.seconds, t.millis }

        return t.value
      end,
    }

    assert.are.equal("2026-10-16T12:50:24.970Z", time.format_iso("2026-10-16T12:50:24.970Z", view))
    assert.are.same({ "2026-10-16T12:50:24.970Z", 1792155024, "970" }, seen)
    assert.are.equal("yesterday", time.format_iso("yesterday", view))
    assert.are.same({ "yesterday" }, seen)
    assert.are.equal("1760619024970389138", time.format_epoch(1760619024, "970", view, "1760619024970389138"))
  end)

  it("should show the value as written and warn once when a time_format function fails", function()
    local notify = vim.notify
    local warnings = {}
    local view = {
      time_format = function()
        error("boom")
      end,
    }

    vim.notify = function(message)
      warnings[#warnings + 1] = message
    end
    assert.are.equal("2026-10-16T12:50:24Z", time.format_iso("2026-10-16T12:50:24Z", view))
    assert.are.equal("2026-10-16T12:50:25Z", time.format_iso("2026-10-16T12:50:25Z", view))
    vim.notify = notify

    assert.are.equal(1, #warnings)
    assert.is_truthy(warnings[1]:find("boom", 1, true))
  end)

  it("should read a typed date, date and time, or ISO time, without a zone as local time", function()
    local local_midnight = os.time({ year = 2026, month = 10, day = 22, hour = 0, min = 0, sec = 0 })
    local local_ten = os.time({ year = 2026, month = 10, day = 22, hour = 10, min = 0, sec = 5 })

    assert.are.equal(local_midnight, time.parse_input("2026-10-22", false))
    assert.are.equal(local_ten + 0.25, time.parse_input("2026-10-22 10:00:05.25", false))
    assert.are.equal(local_ten - 5, time.parse_input("2026-10-22T10:00", false))
    assert.are.equal(1792663200, time.parse_input("2026-10-22T10:00:00Z", false))
    assert.are.equal(1792656000, time.parse_input("2026-10-22T10:00+02:00", false))
    assert.are.equal(1792663200, time.parse_input("2026-10-22 10:00", true))
  end)

  it("should not read a typed value that is not a time", function()
    assert.is_nil(time.parse_input("10:00", false))
    assert.is_nil(time.parse_input("2026-10-22T10:00 PST", false))
    assert.is_nil(time.parse_input("request_id", false))
  end)

  it("should format an epoch with a new format even within the same second", function()
    assert.are.equal(
      "12:50:24.001",
      time.format_epoch(1760619024, "001", { time_format = "%H:%M:%S.%L", time_utc = true })
    )
    assert.are.equal(
      "Oct 16 12:50",
      time.format_epoch(1760619024, "001", { time_format = "%b %d %H:%M", time_utc = true })
    )
  end)
end)
