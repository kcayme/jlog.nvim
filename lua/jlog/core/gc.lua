-- Garbage collection policy: steadier steps while a workspace is open, time-boxed cycles.
local M = {}

-- the default (200) pays collection debt in one 50-80ms tick at 500k lines; 400 keeps ticks under ~35ms
local STEPMUL = 400

-- nil when Neovim is built with PUC Lua instead of LuaJIT
local has_jit, jit = pcall(require, "jit")
-- open workspaces holding the tuned stepmul, and the user's stepmul to give back once none does
local holders = 0
local saved_stepmul

---Collect in smaller, steadier steps while held: GC settings are global, so only while a workspace is open.
M.hold = function()
  holders = holders + 1
  if holders == 1 then
    -- selene: allow(incorrect_standard_library_use)
    saved_stepmul = collectgarbage("setstepmul", STEPMUL)
  end
end

---Release one hold; the last one gives the user's stepmul back.
M.drop = function()
  if holders == 0 then
    return
  end
  holders = holders - 1
  if holders == 0 then
    -- selene: allow(incorrect_standard_library_use)
    collectgarbage("setstepmul", saved_stepmul)
    saved_stepmul = nil
  end
end

---Run collector steps until its cycle ends or `deadline` passes, so a cycle's debt is paid across ticks.
---@param deadline number `vim.uv.hrtime()` to stop at
---@return boolean collected the cycle ended
M.step = function(deadline)
  local collected

  repeat
    -- selene: allow(incorrect_standard_library_use)
    collected = collectgarbage("step", 0)
  until collected or vim.uv.hrtime() >= deadline

  return collected
end

---Free what a dropped page or workspace leaves pinned by LuaJIT traces, which keep the closures they ran alive.
M.release_compiled = function()
  if has_jit then
    jit.flush()
  end
end

return M
