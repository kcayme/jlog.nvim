local progress = require("jlog.progress")

describe("progress", function()
  local real_has = vim.fn.has
  local real_notify = vim.notify
  local events, notes, autocmd

  before_each(function()
    events, notes = {}, {}
    autocmd = vim.api.nvim_create_autocmd("Progress", {
      callback = function(ev)
        events[#events + 1] = { id = ev.data.id, status = ev.data.status, text = ev.data.text[1] }
      end,
    })
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
  end)

  after_each(function()
    vim.api.nvim_del_autocmd(autocmd)
    vim.fn.has = real_has
    vim.notify = real_notify
    progress.cancel("ws")
  end)

  local function older_neovim()
    vim.fn.has = function(feature)
      return feature == "nvim-0.12" and 0 or real_has(feature)
    end
  end

  it("should send a running then a success progress message under one id on Neovim 0.12+", function()
    progress.begin("ws", "render", "rendering…")
    progress.finish("ws", "render", "rendering done")

    assert.are.same({
      { id = "jlog.render.ws", status = "running", text = "rendering…" },
      { id = "jlog.render.ws", status = "success", text = "rendering done" },
    }, events)
    assert.are.same({}, notes)
  end)

  it("should fall back to vim.notify when Neovim is older than 0.12", function()
    older_neovim()
    progress.begin("ws", "render", "rendering…")
    progress.finish("ws", "render", "rendering done")

    assert.are.same({ "jlog: rendering…", "jlog: rendering done" }, notes)
    assert.are.same({}, events)
  end)

  it("should use vim.notify when the progress option is notify, even on Neovim 0.12+", function()
    require("jlog.config").setup({ progress = "notify" })
    progress.begin("ws", "render", "rendering…")
    progress.finish("ws", "render", "rendering done")
    require("jlog.config").setup()

    assert.are.same({ "jlog: rendering…", "jlog: rendering done" }, notes)
    assert.are.same({}, events)
  end)

  it("should report nothing when the progress option is off", function()
    require("jlog.config").setup({ progress = "off" })
    progress.begin("ws", "render", "rendering…")
    progress.finish("ws", "render", "rendering done")
    progress.cancel("ws")
    require("jlog.config").setup()

    assert.are.same({}, notes)
    assert.are.same({}, events)
  end)

  it("should not report done for work that never reported its start", function()
    progress.finish("ws", "render", "rendering done")

    assert.are.same({}, events)
  end)

  it("should cancel a workspace's running work when it closes", function()
    progress.begin("ws", "load", "loading…")
    progress.begin("other", "load", "loading…")
    progress.cancel("ws")
    progress.finish("ws", "load", "loaded 3 entries")

    assert.are.same(
      { "running", "running", "cancel" },
      vim.tbl_map(function(event)
        return event.status
      end, events)
    )
    assert.are.equal("jlog.load.ws", events[3].id)
    progress.cancel("other")
  end)
end)
