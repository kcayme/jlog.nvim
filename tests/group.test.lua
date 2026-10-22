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
    assert.are.equal(500, list[1].group.status)
    assert.are.equal(3, #list) -- header + 2 entries; groups b and (no request_id) have no match
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
end)
