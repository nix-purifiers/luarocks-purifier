# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.luarocks-purifier`, made with lib.makeScope from pkgs/. The
# scope holds the builder `buildLuarocksProject`
# (pkgs/build-luarocks-project/default.nix), the command `cli` and the tool
# stand-ins `shims`. A package written for callPackage takes the scope by
# name, and `luarocks-purifier.overrideScope` replaces what the scope shares.
#
# The overlay gives the builder the shared nix-purifiers library
# (github:nix-purifiers/purifier), which it fetches with, and gives the
# command a flake reference to the library's locked source, which the command
# loads in its own Nix builds.
#
# A consumer that lists this flake in `projects` holds the overlay as
# `luarocks-purifier/default`, which its package sets apply by default.
{ closure-inputs, closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "luarocks-purifier";
  purifierInput = closure-inputs.purifier;
  purifierFlake = "path:${purifierInput.outPath}?narHash=${purifierInput.narHash}";
in
{
  overlay =
    final: prev:
    let
      base = packages final prev;
    in
    base
    // {
      luarocks-purifier = base.luarocks-purifier.overrideScope (
        _: super: {
          luaSDKs = import ../../pkgs/lua-sdks/default.nix { pkgs = final; };
          cli = super.cli.override { inherit purifierFlake; };
          buildLuarocksProject = super.buildLuarocksProject.override { inherit (closure-lib) purifier; };
        }
      );
    };
}
