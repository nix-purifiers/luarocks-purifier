-- SPDX-License-Identifier: MIT
--
-- The LuaRocks configuration of `luarocks-purifier publish`. LuaRocks'
-- default leaves certificate checks off, so that curl would send the API
-- key over a connection it does not verify. The upload API key stays in
-- LuaRocks' own upload configuration (~/.luarocks/upload_config.lua).
check_certificates = true
variables = {
  WGET = "/nonexistent/wget",
}
