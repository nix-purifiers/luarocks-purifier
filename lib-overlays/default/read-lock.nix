# SPDX-License-Identifier: MIT
#
# readLock: the lock in memory of the purifier contract, which the flake's
# library holds as `lib.luarocks-purifier.readLock`. It reads the
# luarocks-purifier lockfile, checked against the rockspecs and the
# luarocks.lock of `src`, into the shape every purifier shares:
#
#   purifier  "luarocks-purifier"
#   entries   the download entries of the lockfile, in the shape of the
#             shared purifier library; every rock is platform-neutral, so
#             no entry carries `systems`
#   outputs   one attribute per rock, by package name: its rockspec `file`,
#             `version`, whether it has `tests`, and the commands (`bin`),
#             Lua modules (`lua`) and C modules (`lib`) it installs
#   problems  the message of lock-problem.nix, when the lockfile is out of
#             date, changed by hand, not valid, or of another format version
#
# `entries` and `outputs` are empty when there is a problem. Nix cannot
# catch a parse error, so a lockfile that is not valid JSON fails
# evaluation with an error context that names `luarocks-purifier lock`; the
# commands of luarocks-purifier check the file before Nix reads it.
{
  # The project source, or null to read the lockfile without checking that
  # it is current.
  src,
  lockFile ? src + "/luarocks-purifier.lock.json",
  # LuaRocks' own lockfile, when it comes from outside src.
  luarocksLock ? null,
}:
let
  parsed = builtins.addErrorContext "luarocks-purifier: ${toString lockFile} is not valid JSON. Run `luarocks-purifier lock` in the project root." (
    builtins.fromJSON (builtins.readFile lockFile)
  );
  problem = import ./lock-problem.nix {
    inherit parsed src luarocksLock;
    name = toString lockFile;
  };
  usable = problem == null;
in
{
  purifier = "luarocks-purifier";
  entries = if usable then parsed.downloads else [ ];
  outputs =
    if usable then
      builtins.listToAttrs (
        map (r: {
          name = r.package;
          value = {
            inherit (r) file version tests;
            inherit (r.outputs) bin lib lua;
          };
        }) parsed.rockspecs
      )
    else
      { };
  problems = if usable then [ ] else [ problem ];
}
