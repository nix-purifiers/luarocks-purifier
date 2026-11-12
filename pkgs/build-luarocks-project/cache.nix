# SPDX-License-Identifier: MIT
#
# The offline cache of a lockfile, which the sandboxed build and the
# interactive mode (`luarocks-purifier luarocks`) both use:
#
#   server/          a rocks server of the locked rockspecs and rocks, with a
#                    manifest that luarocks-admin makes for them
#   files.json       every locked file by the URL LuaRocks downloads it from
#                    (and by each mirror URL), mapped to its store path
#   checkouts.json   every locked checkout, by the request LuaRocks makes
#                    ("<kind> <url> <ref>"), mapped to its store path and,
#                    for git, the identifier LuaRocks reads with `git log`
#   externals.json   the directories of the C libraries the rocks need,
#                    which go to LuaRocks' external_deps_dirs
#   libc             the C library (see libc.nix), which goes last in
#                    external_deps_dirs
#
# luarocks-purifier-curl and luarocks-purifier-git (and -hg, -svn, -cvs)
# serve LuaRocks' downloads from files.json and checkouts.json.
{
  lib,
  pkgs,
  luaSDKs ? import ../lua-sdks { inherit pkgs; },
  runCommand,
  writeText,
  symlinkJoin,
  unzip,
  zip,
  zstd,
  python3,
  # The fetchers for the locked downloads; `fetchers` below replaces any of
  # them.
  fetchurl,
  fetchgit,
  fetchhg,
  fetchsvn,
  fetchcvs,
  # The `purifier` namespace of the shared nix-purifiers library
  # (github:nix-purifiers/purifier), whose fetchEntry fetches each entry.
  purifier,
  lockFile,
  # The project source, when there is one: the lock reader checks that the
  # lockfile is current for it (see lock.nix).
  projectSource ? null,
  # LuaRocks' own lockfile, when it comes from outside the project source.
  luarocksLock ? null,
  # Fetchers that replace those of nixpkgs for the entries, by name
  # (fetchurl, fetchgit, fetchhg, fetchsvn, fetchcvs), for credentials or
  # mirrors. purifier.fetchEntry calls each with the arguments of the
  # nixpkgs fetcher of the same name.
  fetchers ? { },
  # The C libraries the rocks need, as a list of packages. The default is
  # the nixpkgs attributes the lockfile names in externalDeps.
  externalDeps ? null,
}:
let
  lock = import ../../lib-overlays/default/lock.nix {
    inherit lockFile luarocksLock purifier;
    src = projectSource;
  };
  fetch = purifier.fetchEntry (
    {
      inherit
        fetchurl
        fetchgit
        fetchhg
        fetchsvn
        fetchcvs
        runCommand
        unzip
        zstd
        python3
        writeText
        ;
    }
    // fetchers
  );
  luarocks = luaSDKs.${lock.lua}.luarocks;

  # The downloads of the lock in memory for this system, which are all of
  # them: every rock the lock run locks is platform-neutral.
  fetched = builtins.listToAttrs (
    map (d: {
      name = d.path;
      value = fetch d;
    }) (purifier.entriesFor pkgs.stdenv.hostPlatform.system lock.inMemory)
  );

  files = builtins.listToAttrs (
    lib.concatMap (
      d:
      map (url: {
        name = url;
        value = "${fetched.${d.path}}";
      }) ([ d.url ] ++ d.mirrors)
    ) (lock.serverFiles ++ lock.otherFiles)
  );

  # The kind of a checkout is the kind key of its download entry.
  checkoutKind =
    c:
    builtins.head (
      builtins.filter (k: lock.downloadsByPath.${c.path} ? ${k}) [
        "git"
        "hg"
        "svn"
        "cvs"
      ]
    );
  checkouts = builtins.listToAttrs (
    map (c: {
      name = "${checkoutKind c} ${c.request} ${if c.ref == null then "" else c.ref}";
      value = {
        path = "${fetched.${c.path}}";
        identifier = c.identifier or null;
      };
    }) lock.checkouts
  );

  externalPackages =
    if externalDeps != null then
      externalDeps
    else
      map (
        name:
        lib.attrByPath (lib.splitString "." name)
          (throw "luarocks-purifier: nixpkgs has no attribute ${name}, which ${toString lockFile} names in externalDeps")
          pkgs
      ) lock.externalDeps;

  # LuaRocks looks for a C library's headers and libraries under one
  # directory, which a package with separate dev and out outputs does not
  # provide, so each library is all of its outputs joined.
  externals = map (
    p:
    symlinkJoin {
      name = "luarocks-purifier-external-${p.pname or p.name}";
      paths = p.all or [ p ];
    }
  ) externalPackages;

  libc = pkgs.callPackage ../libc { };
in
runCommand "luarocks-purifier-cache"
  {
    nativeBuildInputs = [
      luarocks
      unzip
      zip
    ];
    filesJson = writeText "files.json" (builtins.toJSON files);
    checkoutsJson = writeText "checkouts.json" (builtins.toJSON checkouts);
    externalsJson = writeText "externals.json" (builtins.toJSON (map toString externals));
    passthru = {
      inherit
        lock
        fetched
        externals
        libc
        luarocks
        ;
    };
  }
  ''
    mkdir -p $out/server
    ${lib.concatMapStrings (d: ''
      cp ${fetched.${d.path}} $out/server/${lib.escapeShellArg (baseNameOf d.path)}
    '') lock.serverFiles}
    chmod -R u+w $out/server
    export HOME=$TMPDIR LUA_INIT=@${../cli/tmpname.lua}
    luarocks-admin make_manifest $out/server
    cp $filesJson $out/files.json
    cp $checkoutsJson $out/checkouts.json
    cp $externalsJson $out/externals.json
    ln -s ${libc} $out/libc
  ''
