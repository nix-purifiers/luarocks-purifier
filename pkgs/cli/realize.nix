# SPDX-License-Identifier: MIT
#
# What `luarocks-purifier prefetch` and `luarocks-purifier luarocks` build:
# the offline cache of the lockfile, the same derivation the sandboxed build
# uses. The CLI builds it with an out-link in the project, which is the GC
# root that keeps every locked file alive. The CLI checks that the lockfile
# is current for the project before it builds this.
{
  lockFile,
  # The nixpkgs the CLI was built with.
  nixpkgs,
  # The shared nix-purifiers library the CLI was built with, as a flake
  # reference to its locked source.
  purifierFlake,
  sdkFile ? null,
}:
let
  pkgs = import nixpkgs { };
in
pkgs.callPackage ../build-luarocks-project/cache.nix {
  inherit lockFile;
  luaSDKs = if sdkFile == null then import ../lua-sdks { inherit pkgs; } else import sdkFile;
  inherit ((builtins.getFlake purifierFlake).lib) purifier;
}
