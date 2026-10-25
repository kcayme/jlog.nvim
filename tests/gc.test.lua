local gc = require("jlog.core.gc")

---The current stepmul; setting it is the only way to read it, so it is set back right away.
local function stepmul()
  local value = collectgarbage("setstepmul", 200)

  collectgarbage("setstepmul", value)

  return value
end

describe("gc", function()
  local user_stepmul

  before_each(function()
    user_stepmul = collectgarbage("setstepmul", 150)
  end)

  after_each(function()
    collectgarbage("setstepmul", user_stepmul)
  end)

  it("should tune the stepmul while held and give the user's back when the last holder drops", function()
    gc.hold()
    gc.hold()
    assert.are.equal(400, stepmul())

    gc.drop()
    assert.are.equal(400, stepmul())

    gc.drop()
    assert.are.equal(150, stepmul())
  end)

  it("should leave the stepmul alone when dropped without a hold", function()
    gc.drop()

    assert.are.equal(150, stepmul())
  end)

  it("should step the collector until its cycle ends when the deadline allows", function()
    local garbage = {}

    for index = 1, 10000 do
      garbage[index] = { index }
    end
    garbage = nil

    assert.is_true(gc.step(vim.uv.hrtime() + 5e9))
  end)
end)
