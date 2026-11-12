# SPDX-License-Identifier: MIT
#
# What `luarocks-purifier publish` builds: the `release` of the project at
# `src`, the source rocks that the sandboxed build packs.
{
  src,
  lockFile,
  # The path of luarocks.lock when it lies outside src, or null.
  luarocksLock ? null,
  # The nixpkgs the CLI was built with.
  nixpkgs,
  # The shared nix-purifiers library the CLI was built with, as a flake
  # reference to its locked source.
  purifierFlake,
  sdkFile ? null,
  # Keep the selected shim identity when this file runs from a filtered source.
  shimsVersion ? null,
}:
let
  pkgs = import nixpkgs { };
  buildLuarocksProject = pkgs.callPackage ./build-luarocks-project.nix {
    luaSDKs = if sdkFile == null then import ./lua-sdks.nix { inherit pkgs; } else import sdkFile;
    shims = pkgs.callPackage ../../pkgs/shims (
      pkgs.lib.optionalAttrs (shimsVersion != null) { version = shimsVersion; }
    );
    inherit ((builtins.getFlake purifierFlake).lib) purifier;
  };
in
(buildLuarocksProject { inherit src lockFile luarocksLock; }).release
