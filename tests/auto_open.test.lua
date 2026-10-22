local function copy_to_temp(bytes, ext)
  local path = vim.fn.tempname() .. ext

  vim.fn.writefile(vim.split(bytes, "\n", { plain = true }), path, "b")

  return path
end

local function read_bytes(path)
  return table.concat(vim.fn.readfile(path, "b"), "\n")
end

---What a normal read would give: buffer state that auto-open must reproduce exactly.
local function snapshot()
  return {
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
    fileformat = vim.bo.fileformat,
    fileencoding = vim.bo.fileencoding,
    endofline = vim.bo.endofline,
    filetype = vim.bo.filetype,
    buftype = vim.bo.buftype,
    modifiable = vim.bo.modifiable,
    modified = vim.bo.modified,
    undo_seq = vim.fn.undotree().seq_last,
  }
end

local function open_without_hook(path)
  local saved = vim.o.eventignore

  vim.opt.eventignore:append("BufReadCmd")
  vim.cmd("tabedit " .. vim.fn.fnameescape(path))
  vim.o.eventignore = saved
end

describe("auto open", function()
  before_each(function()
    require("jlog").setup()
  end)
  after_each(function()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("should open a workspace instead of loading a recognized log", function()
    vim.cmd("edit tests/fixtures/loki.json")
    assert.is_truthy(vim.api.nvim_buf_get_name(0):find("^jlog://"))
  end)

  it("should open unrecognized files exactly as without jlog, firing BufReadPre and BufReadPost", function()
    local fired = {}
    local group = vim.api.nvim_create_augroup("jlog_test", { clear = true })
    for _, event in ipairs({ "BufReadPre", "BufReadPost" }) do
      vim.api.nvim_create_autocmd(event, {
        group = group,
        pattern = "*package.json",
        callback = function()
          fired[event] = true
        end,
      })
    end
    vim.cmd("tabnew tests/fixtures/package.json")
    assert.are.same(vim.fn.readfile("tests/fixtures/package.json"), vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_false(vim.bo.modified)
    assert.are.equal("json", vim.bo.filetype)
    assert.is_true(fired.BufReadPre)
    assert.is_true(fired.BufReadPost)
    vim.api.nvim_del_augroup_by_id(group)
  end)

  it("should open the raw source without auto-open claiming it", function()
    local ws = require("jlog.workspace").open({ path = vim.fn.fnamemodify("tests/fixtures/app.jsonl", ":p") })
    ws:open_raw(3)
    assert.is_nil(vim.api.nvim_buf_get_name(0):find("^jlog://"))
    assert.are.equal(3, vim.fn.line("."))
  end)

  for name, case in pairs({
    ["a plain json file"] = { bytes = read_bytes("tests/fixtures/package.json"), ext = ".json" },
    ["a CRLF file"] = { bytes = "first line\r\nsecond line\r\n", ext = ".txt" },
    ["a file without a final newline"] = { bytes = "no newline at end", ext = ".log" },
  }) do
    it("should read " .. name .. " like a normal read and write it back the same way", function()
      local hooked = copy_to_temp(case.bytes, case.ext)
      local plain = copy_to_temp(case.bytes, case.ext)
      local expected, actual

      open_without_hook(plain)
      expected = snapshot()
      vim.cmd("tabedit " .. vim.fn.fnameescape(hooked))
      actual = snapshot()

      assert.are.same(expected, actual)
      assert.are.equal(0, actual.undo_seq)
      assert.is_false(actual.modified)
      vim.cmd("write")
      -- unchanged files written back match a normal write ('fixeol' may add a final newline)
      vim.cmd("tabprevious | write")
      assert.are.equal(read_bytes(plain), read_bytes(hooked))
      if vim.endswith(case.bytes, "\n") then
        assert.are.equal(case.bytes, read_bytes(hooked))
      end
    end)
  end

  it("should keep a CRLF file in dos format", function()
    local path = copy_to_temp("a\r\nb\r\n", ".txt")

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    assert.are.equal("dos", vim.bo.fileformat)
    assert.are.same({ "a", "b" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  it("should give an empty writable buffer for a new file", function()
    local path = vim.fn.tempname() .. ".json"

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    assert.are.equal(path, vim.api.nvim_buf_get_name(0))
    assert.are.same({ "" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.are.equal("", vim.bo.buftype)
    assert.is_true(vim.bo.modifiable)
    assert.is_false(vim.bo.modified)
    assert.are.equal("json", vim.bo.filetype)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "{}" })
    vim.cmd("write")
    assert.are.same({ "{}" }, vim.fn.readfile(path))
  end)

  it("should reload an unrecognized buffer with :edit!", function()
    local path = copy_to_temp(read_bytes("tests/fixtures/package.json"), ".json")

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "changed" })
    vim.cmd("edit!")
    assert.are.same(vim.fn.readfile(path), vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.is_false(vim.bo.modified)
  end)

  it("should keep a raw buffer of a recognized log raw on :edit!", function()
    local path = copy_to_temp(read_bytes("tests/fixtures/app.jsonl"), ".jsonl")
    local ws = assert(require("jlog.workspace").open({ path = path }))

    ws:open_raw(1)
    vim.cmd("edit!")
    assert.are.equal(path, vim.api.nvim_buf_get_name(0))
    assert.are.same(vim.fn.readfile(path), vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)

  it("should never leave a writable buffer for a recognized log", function()
    local path = copy_to_temp(read_bytes("tests/fixtures/loki.json"), ".json")
    local size = vim.fn.getfsize(path)
    local first_win
    local placeholders = 0

    vim.cmd("tabnew")
    vim.cmd("vsplit")
    first_win = vim.api.nvim_get_current_win()
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    -- the workspace took a new tab: the split showing the placeholder stays behind
    assert.is_truthy(vim.api.nvim_buf_get_name(0):find("^jlog://"))
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(bufnr) == path and vim.api.nvim_buf_is_loaded(bufnr) then
        placeholders = placeholders + 1
        assert.are.equal("nofile", vim.bo[bufnr].buftype)
        assert.is_false(vim.bo[bufnr].modifiable)
        vim.api.nvim_win_call(first_win, function()
          pcall(vim.cmd, "silent! write")
          pcall(vim.cmd, "silent! write!")
        end)
      end
    end
    assert.are.equal(1, placeholders)
    assert.are.equal(size, vim.fn.getfsize(path))

    -- once the edit is done, the window goes back to what it showed before
    assert.is_true(vim.wait(1000, function()
      return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(first_win)) ~= path
    end))
    assert.are.equal(size, vim.fn.getfsize(path))
  end)

  it("should fall back to a normal read with a warning when opening the workspace fails", function()
    local workspace = require("jlog.workspace")
    local original_open, original_notify = workspace.open, vim.notify
    local path = copy_to_temp(read_bytes("tests/fixtures/app.jsonl"), ".jsonl")
    local warned

    workspace.open = function()
      error("boom")
    end
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warned = msg
      end
    end
    local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
    workspace.open, vim.notify = original_open, original_notify

    assert.is_true(ok, err)
    assert.is_truthy(warned and warned:find("boom", 1, true))
    assert.are.same(vim.fn.readfile(path), vim.api.nvim_buf_get_lines(0, 0, -1, false))
    assert.are.equal("", vim.bo.buftype)
    assert.is_true(vim.bo.modifiable)
    assert.is_false(vim.bo.modified)
  end)

  it("should leave files alone when auto-open is disabled", function()
    require("jlog").setup({ auto_open = { enable = false } })
    vim.cmd("edit tests/fixtures/loki.json")
    assert.are.equal(vim.fn.fnamemodify("tests/fixtures/loki.json", ":p"), vim.api.nvim_buf_get_name(0))
  end)
end)
