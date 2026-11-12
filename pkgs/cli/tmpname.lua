-- SPDX-License-Identifier: MIT
--
-- LuaRocks creates temporary files with os.tmpname, which ignores TMPDIR
-- and always uses /tmp. luarocks-purifier runs LuaRocks with LUA_INIT set
-- to this file, which makes os.tmpname use TMPDIR, so that a build
-- directory or a sandbox without a writable /tmp works.
local count = 0
os.tmpname = function()
  count = count + 1
  local dir = os.getenv("TMPDIR") or "/tmp"
  local name = dir .. "/lua_" .. os.time() .. "_" .. count .. "_" .. math.random(1, 1000000000)
  local file = assert(io.open(name, "w"))
  file:close()
  return name
end
