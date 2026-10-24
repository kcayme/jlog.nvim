local workers = require("jlog.worker")

local function wait_for(callback_args)
  vim.wait(2000, function()
    return callback_args.done
  end)
end

describe("workers", function()
  local real_new_work = vim.uv.new_work
  local real_path = package.path

  after_each(function()
    workers.disabled = nil
    vim.uv.new_work = real_new_work
    package.path = real_path
    package.loaded["jlog.worker"] = nil
    workers = require("jlog.worker")
  end)

  it("should report an error and release the slot when queueing raises", function()
    local got = {}

    package.loaded["jlog.worker"] = nil
    workers = require("jlog.worker")
    workers.run("parse_lines", {}, function(err)
      got.err, got.done = err, true
    end)
    wait_for(got)

    assert.is_string(got.err)
    assert.are.equal(0, workers.in_flight())
  end)

  it("should report an error and release the slot when queueing fails", function()
    local got = {}

    vim.uv.new_work = function()
      return {
        queue = function()
          return nil, "boom"
        end,
      }
    end
    package.loaded["jlog.worker"] = nil
    workers = require("jlog.worker")
    workers.run("parse_lines", "x", function(err)
      got.err, got.done = err, true
    end)
    wait_for(got)

    assert.is_truthy(got.err:find("boom", 1, true))
    assert.are.equal(0, workers.in_flight())
  end)

  it("should become unavailable and report an error when creating the work handle fails", function()
    local got = {}

    vim.uv.new_work = function()
      error("no threads")
    end
    package.loaded["jlog.worker"] = nil
    workers = require("jlog.worker")
    workers.run("parse_lines", "x", function(err)
      got.err, got.done = err, true
    end)
    wait_for(got)

    assert.is_string(got.err)
    assert.is_false(workers.available())
  end)

  it("should report an error when a job returns a non-string", function()
    local dir = vim.fn.tempname()
    local script = dir .. "/run.lua"
    local result

    -- a child process keeps the fake jlog.worker.jobs out of this process's cached pool threads
    vim.fn.mkdir(dir .. "/jlog/worker", "p")
    vim.fn.writefile({ "return { bad = function() return {} end }" }, dir .. "/jlog/worker/jobs.lua")
    vim.fn.writefile({
      "package.path = '" .. dir .. "/?.lua;' .. package.path",
      -- no rtp: the thread's own rtp loader would find the real jlog.worker.jobs first
      "package.path = package.path .. ';" .. vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua'",
      "local done",
      "require('jlog.worker').run('bad', 'x', function(err, res)",
      "  io.stdout:write(tostring(err) .. '|' .. tostring(res))",
      "  done = true",
      "end)",
      "vim.wait(3000, function() return done end)",
    }, script)
    result = vim.system({ "nvim", "--headless", "-u", "NONE", "-l", script }, { text = true }):wait(10000)
    vim.fn.delete(dir, "rf")

    assert.are.equal(0, result.code, "child process failed or timed out: " .. tostring(result.stderr))

    assert.is_truthy(result.stdout:find("expected a string", 1, true))
    assert.is_truthy(result.stdout:find("|nil", 1, true))
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

  it("should fall back when the plugin path cannot be resolved", function()
    local got = {}
    local source = table.concat(vim.fn.readfile("lua/jlog/worker/init.lua"), "\n")
    local unresolved = load(source, "=unresolvable")()

    unresolved.run("parse_lines", "x", function(err)
      got.err, got.done = err, true
    end)
    wait_for(got)

    assert.is_false(unresolved.available())
    assert.is_truthy(got.err)
  end)
end)
