# SPDX-License-Identifier: MIT
#
# The luarocks-purifier scope: the builder, the command and the tool
# stand-ins. The default package overlay makes it with lib.makeScope, gives
# the builder the `purifier` namespace of the shared nix-purifiers library
# and the command a flake reference to its locked source, and adds the scope
# to the package set as `pkgs.luarocks-purifier`.
{ callPackage, ... }:
let
  version = import ./version.nix;
in
rec {
  # The tool stand-ins LuaRocks runs in the lock run and offline.
  shims = callPackage ./shims { };
  # The luarocks-purifier command.
  cli = callPackage ./cli { inherit version shims; };
  # The builder (nix/lib/build-luarocks-project.nix), which fetches with the
  # shared library.
  buildLuarocksProject = callPackage ../nix/lib/build-luarocks-project.nix { };
}
