# SPDX-License-Identifier: MIT
{ pkgs }:
builtins.mapAttrs (name: lua: {
  inherit lua;
  luarocks = lua.pkgs.luarocks;
  luaExecutable = if name == "luajit" then "luajit" else "lua";
  luaVersion = lua.version;
  luarocksVersion = lua.pkgs.luarocks.version;
}) (import ./lua.nix { inherit pkgs; })
