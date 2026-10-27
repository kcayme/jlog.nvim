local dispatcher = require("jlog.worker.dispatcher")
local workers = require("jlog.worker")

describe("dispatcher", function()
  local stall_ms = workers.stall_ms

  after_each(function()
    workers.stall_ms = stall_ms
  end)

  it("should put a job's result on the job and note when it reported", function()
    local sender = dispatcher.new()
    local job = dispatcher.send(sender, "count_entries", { entries = {} }, {})
    local sent_at = sender.at

    assert.is_true(vim.wait(5000, function()
      return job.done == true
    end, 10))
    assert.is_nil(job.err)
    assert.are.same({}, vim.mpack.decode(job.result).fields)
    assert.is_true(sender.at >= sent_at)
  end)

  it("should report a stall once nothing happened for stall_ms, until progress is noted", function()
    local sender = dispatcher.new()

    workers.stall_ms = 20
    assert.is_false(dispatcher.stalled(sender))
    vim.wait(40)
    assert.is_true(dispatcher.stalled(sender))
    dispatcher.progress(sender)
    assert.is_false(dispatcher.stalled(sender))
  end)

  it("should have room only under the caller's own cap", function()
    assert.is_true(dispatcher.has_room(0))
    assert.is_false(dispatcher.has_room(workers.limit()))
  end)
end)
