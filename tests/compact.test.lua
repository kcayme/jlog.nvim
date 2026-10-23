local config = require("jlog.config")
local compact = require("jlog.ui.compact")

describe("compact", function()
  local notify = vim.notify

  after_each(function()
    vim.notify = notify
  end)

  it("should be inactive with default options", function()
    assert.is_false(compact.resolve(config.setup()).active)
  end)

  it("should rank order and status aliases", function()
    local resolved = compact.resolve(config.setup({ compact = { order = { "a", "b", "a" } } }))

    assert.are.same({ a = 1, b = 2 }, resolved.rank_of)
    assert.is_true(resolved.status.status_code)
  end)

  it("should pick a field's style by path, then role, then default", function()
    local resolved = compact.resolve(config.setup({
      compact = { style = "pill", fields = { ["req.host"] = { style = "plain" }, level = { style = "inverted" } } },
    }))

    assert.are.equal("plain", compact.style_of(resolved, "req.host"))
    assert.are.equal("inverted", compact.style_of(resolved, "lvl", "level"))
    assert.are.equal("pill", compact.style_of(resolved, "path"))
    assert.are.equal("plain", compact.style_of(resolved, "ts", "time"))
    assert.are.equal("plain", compact.style_of(resolved, "msg", "message"))
    assert.are.equal("pill", compact.style_of(resolved, "code", "status"))
  end)

  it("should keep the level inverted by default", function()
    local resolved = compact.resolve(config.setup())

    assert.are.equal("inverted", compact.style_of(resolved, "level", "level"))
    assert.are.equal("plain", compact.style_of(resolved, "path"))
  end)

  it("should map status classes and nothing else", function()
    assert.are.equal("JLogStatus2xx", compact.status_group("200"))
    assert.are.equal("JLogStatus3xx", compact.status_group("302"))
    assert.are.equal("JLogStatus4xx", compact.status_group("404"))
    assert.are.equal("JLogStatus5xx", compact.status_group("599"))
    for _, value in ipairs({ "99", "600", "abc", "500 ", "500.0", "1e3" }) do
      assert.is_nil(compact.status_group(value))
    end
  end)

  it("should call a format with one reused context and fall back when it fails", function()
    local entry, seen, count = {}, nil, 0
    local resolved = compact.resolve(config.setup({
      compact = {
        fields = {
          status = {
            format = function(ctx)
              seen = ctx

              return ctx.key .. " " .. ctx.value, "DiagnosticInfo"
            end,
          },
          boom = {
            format = function()
              error("bad")
            end,
          },
          none = {
            format = function() end,
          },
          num = {
            format = function()
              return 42
            end,
          },
        },
      },
    }))

    vim.notify = function()
      count = count + 1
    end

    local text, highlight = compact.format(resolved, "status", nil, "500", entry)
    assert.are.equal("status 500", text)
    assert.are.equal("DiagnosticInfo", highlight)
    assert.are.equal(entry, seen.entry)

    for _, key in ipairs({ "boom", "none", "num" }) do
      assert.is_nil(compact.format(resolved, key, nil, "x", entry))
      assert.is_nil(compact.format(resolved, key, nil, "x", entry))
    end
    assert.are.equal(3, count)
  end)
end)
