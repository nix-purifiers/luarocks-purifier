# SPDX-License-Identifier: MIT
#
# The Lua of each version a lockfile can name in `lua`.
{ pkgs }:
{
  "5.1" = pkgs.lua5_1;
  "5.2" = pkgs.lua5_2;
  "5.3" = pkgs.lua5_3;
  "5.4" = pkgs.lua5_4;
  "5.5" = pkgs.lua5_5;
  luajit = pkgs.luajit;
}
