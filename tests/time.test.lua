local time = require("jlog.ui.time")

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
