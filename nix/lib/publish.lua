-- SPDX-License-Identifier: MIT
-- Native upload clients predating the source-rock argument always call pack.
-- Give that native uploader the already-built archive, without resolving source.
dofile(assert(os.getenv("LUAROCKS_PURIFIER_LIB")) .. "/tmpname.lua")
local archive = assert(os.getenv("LUAROCKS_PURIFIER_RELEASE_ROCK"))
local expected = assert(os.getenv("LUAROCKS_PURIFIER_RELEASE_SPEC"))
local native_require = require
require = function(name)
  local loaded, extra = native_require(name)
  if name == "luarocks.pack" then
    loaded.pack_source_rock = function(spec)
      local fs = native_require("luarocks.fs")
      assert(fs.absolute_name(spec) == fs.absolute_name(expected), "unexpected publication rockspec")
      return archive
    end
    require = native_require
  end
  return loaded, extra
end
