local utils = require("jlog.utils")

describe("utils.tick_deadline", function()
  it("should share one deadline between jobs run in the same loop pass", function()
    local first, second

    -- no loop pass runs between these calls, so they share the first one's budget
    first = utils.tick_deadline(1e9)
    second = utils.tick_deadline(1e9)
    assert.are.equal(first, second)
  end)

  it("should cap a job's deadline at its own budget", function()
    local before = vim.uv.hrtime()

    utils.tick_deadline(1e12)
    assert.is_true(utils.tick_deadline(0) <= vim.uv.hrtime())
    assert.is_true(utils.tick_deadline(1e12) - before < 2e12)
  end)

  it("should start a new deadline in the next loop pass", function()
    local first = utils.tick_deadline(0)
    local later

    vim.wait(5)
    later = utils.tick_deadline(1e9)
    assert.is_true(later > first + 5e8)
  end)
end)
