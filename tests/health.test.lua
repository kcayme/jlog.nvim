local jlog = require("jlog")

describe("jlog.health_check", function()
  local real_has = vim.fn.has

  after_each(function()
    vim.fn.has = real_has
  end)

  it("should pass when Neovim meets the minimum version", function()
    local ok, err = jlog.health_check()

    assert.is_true(ok)
    assert.is_nil(err)
  end)

  it("should fail with the minimum version when Neovim is older", function()
    local ok, err

    vim.fn.has = function(feature)
      return feature == "nvim-0.10" and 0 or real_has(feature)
    end
    ok, err = jlog.health_check()

    assert.is_false(ok)
    assert.are.equal("jlog requires Neovim >= 0.10", err)
  end)
end)

describe(":checkhealth jlog", function()
  local real_has = vim.fn.has
  local real_health = vim.health
  local reports

  before_each(function()
    reports = {}
    vim.health = {
      start = function() end,
      ok = function(msg)
        reports[#reports + 1] = { "ok", msg }
      end,
      error = function(msg)
        reports[#reports + 1] = { "error", msg }
      end,
    }
  end)

  after_each(function()
    vim.fn.has = real_has
    vim.health = real_health
  end)

  it("should report ok when Neovim meets the minimum version", function()
    require("jlog.health").check()

    assert.are.equal("ok", reports[1][1])
  end)

  it("should report an error with the minimum version when Neovim is older", function()
    vim.fn.has = function(feature)
      return feature == "nvim-0.10" and 0 or real_has(feature)
    end
    require("jlog.health").check()

    assert.are.same({ { "error", "jlog requires Neovim >= 0.10" } }, reports)
  end)
end)

describe("jlog.setup", function()
  local config = require("jlog.config")
  local real_has = vim.fn.has
  local real_notify = vim.notify

  after_each(function()
    vim.fn.has = real_has
    vim.notify = real_notify
    config.setup()
  end)

  it("should report and keep the options unchanged when Neovim is older than the minimum", function()
    local before = config.options
    local message

    vim.fn.has = function(feature)
      return feature == "nvim-0.10" and 0 or real_has(feature)
    end
    vim.notify = function(msg)
      message = msg
    end
    jlog.setup({ sidebar = { width = 99 } })

    assert.are.equal("jlog requires Neovim >= 0.10", message)
    assert.are.equal(before, config.options)
  end)
end)
