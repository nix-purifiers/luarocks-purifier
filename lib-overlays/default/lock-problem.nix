# SPDX-License-Identifier: MIT
#
# What is wrong with a parsed lockfile, as the message that read-lock.nix
# puts in the `problems` of the lock in memory, or null when nothing is.
# Given the project source, a lockfile that was made from other rockspecs,
# or from another luarocks.lock, is out of date.
{
  parsed,
  # The name of the lockfile in messages.
  name,
  src ? null,
  # LuaRocks' own lockfile, when the builder takes it from outside src. It
  # replaces any luarocks.lock in src.
  luarocksLock ? null,
}:
let
  supportedVersion = import ./lock-version.nix;
  contentHash = import ./content-hash.nix;

  lock = "Run `luarocks-purifier lock` in the project root.";
  problem = message: "luarocks-purifier: ${name} ${message} ${lock}";

  # The fields every lockfile has, which the builder reads.
  fields = [
    "version"
    "contentHash"
    "lua"
    "servers"
    "externalDeps"
    "definitionHash"
    "rockspecs"
    "downloads"
    "checkouts"
  ];
  missing = builtins.filter (f: !(parsed ? ${f})) fields;

  # The definition hash of the source, as `luarocks-purifier lock` computes
  # it (see definition_hash in bin/luarocks-purifier).
  definitionHash =
    let
      luarocksLockFile =
        if luarocksLock != null then
          luarocksLock
        else if builtins.pathExists (src + "/luarocks.lock") then
          src + "/luarocks.lock"
        else
          null;
      files = builtins.sort builtins.lessThan (
        map (r: r.file) parsed.rockspecs ++ (if luarocksLockFile != null then [ "luarocks.lock" ] else [ ])
      );
      path = f: if f == "luarocks.lock" then luarocksLockFile else src + "/${f}";
      lines = builtins.concatStringsSep "" (
        map (f: "${f} ${builtins.hashFile "sha256" (path f)}\n") files
      );
    in
    builtins.convertHash {
      hash = builtins.hashString "sha256" lines;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };
in
if !builtins.isAttrs parsed then
  problem "is not a luarocks-purifier lockfile."
else if parsed ? version && parsed.version != supportedVersion then
  "luarocks-purifier: ${name} has lock format version ${builtins.toJSON parsed.version}; this library reads version ${toString supportedVersion}. Run `luarocks-purifier lock` with the luarocks-purifier version that provides this library."
else if missing != [ ] then
  problem "is not a valid lockfile: it has no ${builtins.concatStringsSep ", " missing}."
else if parsed.contentHash != contentHash parsed then
  problem "was changed after `luarocks-purifier lock` wrote it: its contentHash does not match its content."
else if
  src != null && !(builtins.all (r: builtins.pathExists (src + "/${r.file}")) parsed.rockspecs)
then
  problem "names a rockspec that the project source does not have."
else if src != null && definitionHash != parsed.definitionHash then
  problem "is out of date: a rockspec or luarocks.lock changed since the lock run."
else
  null
