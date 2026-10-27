local config = require("jlog.config")
local workspace = require("jlog.workspace")

local gen = dofile("bench/gen.lua")

-- enough entries for the load, query and render loops to get compiled by LuaJIT
local ENTRIES = 20000
local PAGE_ENTRIES = 20000

describe("memory", function()
  local path

  before_each(function()
    -- compile every loop at once, so whether a trace pins a dropped table does not depend on how hot it ran
    jit.opt.start("hotloop=1")
    path = vim.fn.tempname() .. ".jsonl"
    vim.fn.writefile(gen.nested_lines(ENTRIES), path)
  end)
  after_each(function()
    jit.opt.start("hotloop=56")
    config.setup()
    pcall(vim.cmd, "silent! tabonly")
    vim.fn.delete(path)
  end)

  local function settled(ws)
    return function()
      return not ws.loading and ws.indexing == nil and ws.view.complete and ws.rendered == ws.engine.generation
    end
  end

  local function collect()
    vim.wait(200)
    collectgarbage()
    collectgarbage()
  end

  it("should free a closed workspace and its entries", function()
    local tracked = setmetatable({}, { __mode = "v" })

    config.setup()
    -- in a function so no stack slot of this test keeps the workspace
    local function open_and_close()
      local ws = assert(workspace.open({ path = path }))

      assert.is_true(vim.wait(60000, settled(ws), 5))
      tracked.ws, tracked.entries = ws, ws.entries
      ws:close()
    end

    open_and_close()
    collect()
    assert.is_nil(tracked.ws)
    assert.is_nil(tracked.entries)
  end)

  it("should free a page's entries once another page replaces them", function()
    local tracked = setmetatable({}, { __mode = "v" })
    local ws

    -- larger pages than the close test: the old page's loops must run hot enough to be compiled
    vim.fn.writefile(gen.nested_lines(2 * PAGE_ENTRIES), path)
    config.setup({ paging = { size = PAGE_ENTRIES, overlap = 100 } })
    local function open_and_turn_page()
      ws = assert(workspace.open({ path = path }))
      assert.is_true(vim.wait(60000, settled(ws), 5))
      tracked.first = ws.entries
      ws:goto_page(2)
      assert.is_true(vim.wait(60000, function()
        return ws.page == 2 and settled(ws)()
      end, 5))
    end

    open_and_turn_page()
    collect()
    assert.is_nil(tracked.first)
    ws:close()
  end)
end)
