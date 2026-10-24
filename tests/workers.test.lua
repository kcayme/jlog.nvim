local workers = require("jlog.workers")

describe("workers", function()
  after_each(function()
    workers.disabled = nil
  end)

  it("should return a job's result from a worker thread", function()
    local got_err, got_result, done

    workers.run("parse_lines", vim.mpack.encode({ text = '{"msg":"a"}\nplain' }), function(err, result)
      got_err, got_result, done = err, result, true
    end)
    vim.wait(2000, function()
      return done
    end)

    assert.is_nil(got_err)
    assert.are.same({ 1, 0 }, vim.mpack.decode(got_result).positions)
  end)

  it("should report a job's error instead of raising", function()
    local got_err, got_result, done

    workers.run("parse_lines", "not mpack", function(err, result)
      got_err, got_result, done = err, result, true
    end)
    vim.wait(2000, function()
      return done
    end)

    assert.is_string(got_err)
    assert.is_nil(got_result)
  end)

  it("should count jobs in flight", function()
    local finished = 0
    local payload = vim.mpack.encode({ text = "{}" })

    workers.run("parse_lines", payload, function()
      finished = finished + 1
    end)
    workers.run("parse_lines", payload, function()
      finished = finished + 1
    end)
    assert.are.equal(2, workers.in_flight())

    vim.wait(2000, function()
      return finished == 2
    end)

    assert.are.equal(0, workers.in_flight())
  end)

  it("should not be available when disabled", function()
    workers.disabled = true

    assert.is_false(workers.available())
  end)

  it("should limit workers to the thread pool size minus one", function()
    assert.is_true(workers.limit() >= 1)
  end)
end)
