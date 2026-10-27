local group = require("jlog.query.group")
local rows = {
  { request_id = "a", status = 200, msg = "start" },
  { request_id = "b", msg = "app log" },
  { request_id = "a", status = 500, msg = "done" },
  { msg = "no id" },
}
local function get(i, path)
  return rows[i][path]
end

describe("group.build", function()
  it("should filter and keep order without grouping", function()
    local list, shown = group.build(#rows, {
      pred = function(i)
        return rows[i].status ~= nil
      end,
      get = get,
    })
    assert.are.equal(2, shown)
    assert.are.same(
      { 1, 3 },
      vim.tbl_map(function(item)
        return item.idx
      end, list)
    )
  end)

  it("should reverse", function()
    local list = group.build(#rows, {
      pred = function()
        return true
      end,
      get = get,
      reverse = true,
    })
    assert.are.equal(4, list[1].idx)
  end)

  it("should keep whole groups when any member matches and put missing values last", function()
    local list = group.build(#rows, {
      pred = function(i)
        return (rows[i].status or 0) >= 500
      end,
      field = "request_id",
      get = get,
    })
    assert.are.equal("header", list[1].kind)
    assert.are.same({ 1, 3 }, list[1].group.idxs)
    assert.are.equal(3, #list) -- header + 2 entries; groups b and (no request_id) have no match
  end)

  it("should stop at the limit, taking the first entries in display order", function()
    local list, shown = group.build(#rows, {
      pred = function()
        return true
      end,
      get = get,
      reverse = true,
      limit = 2,
    })
    assert.are.equal(2, shown)
    assert.are.same(
      { 4, 3 },
      vim.tbl_map(function(item)
        return item.idx
      end, list)
    )
  end)

  it("should show only the first groups up to the group limit", function()
    local list, shown = group.build(#rows, {
      pred = function()
        return true
      end,
      field = "request_id",
      get = get,
      group_limit = 1,
    })
    assert.are.equal(2, shown)
    assert.are.equal(3, #list) -- header of group a and its 2 entries
    assert.are.equal("a", list[1].group.label)
  end)

  it("should cut the last group short when the limit is reached inside it", function()
    local list, shown = group.build(#rows, {
      pred = function()
        return true
      end,
      field = "request_id",
      get = get,
      group_limit = 2,
      limit = 1,
    })
    assert.are.equal(1, shown)
    assert.are.same({ "header", "entry" }, { list[1].kind, list[2].kind })
    assert.are.equal(2, #list)
  end)

  it("should label the missing-value group", function()
    local list = group.build(#rows, {
      pred = function()
        return true
      end,
      field = "request_id",
      get = get,
    })
    assert.are.equal("(no request_id)", list[#list - 1].group.label)
  end)

  it("should keep only the matching entries of the missing-value group", function()
    local lines = {
      { request_id = "a", level = "INFO" },
      { msg = "startup", level = "INFO" },
      { request_id = "a", level = "ERROR" },
      { msg = "disk full", level = "ERROR" },
      { msg = "heartbeat", level = "INFO" },
    }
    local list = group.build(#lines, {
      pred = function(i)
        return lines[i].level == "ERROR"
      end,
      field = "request_id",
      get = function(i, path)
        return lines[i][path]
      end,
    })

    assert.are.same({ 1, 3 }, list[1].group.idxs)
    assert.are.equal("(no request_id)", list[4].group.label)
    assert.are.same({ 4 }, list[4].group.idxs)
    assert.are.equal(5, #list)
  end)

  it("should put the missing-value group last when the newest is on top", function()
    for _, order in ipairs({ { newest_first = true }, { reverse = true } }) do
      local list = group.build(#rows, {
        pred = function()
          return true
        end,
        field = "request_id",
        get = get,
        newest_first = order.newest_first,
        reverse = order.reverse,
      })
      local last_header

      for _, item in ipairs(list) do
        if item.kind == "header" then
          last_header = item
        end
      end
      assert.are.equal("(no request_id)", last_header.group.label)
      assert.are_not.equal("(no request_id)", list[1].group.label)
    end
  end)

  it("should build the same items when a checkpoint is given, and call it", function()
    local many = {}
    for i = 1, 10000 do
      many[i] = { request_id = tostring(i % 7), status = i }
    end
    local calls = 0
    local function args(field, reverse, checkpoint)
      return {
        pred = function(i)
          return i % 3 ~= 0
        end,
        field = field,
        reverse = reverse,
        get = function(i, path)
          return many[i][path]
        end,
        checkpoint = checkpoint,
      }
    end
    local function count_calls()
      calls = calls + 1
    end

    for _, field in ipairs({ false, "request_id" }) do
      for _, reverse in ipairs({ false, true }) do
        local plain = { group.build(#many, args(field or nil, reverse)) }
        local checked = { group.build(#many, args(field or nil, reverse, count_calls)) }
        assert.are.same(plain, checked)
      end
    end
    assert.is_true(calls > 0)
  end)
end)
