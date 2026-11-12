# SPDX-License-Identifier: MIT
#
# The C library of the nixpkgs compiler, with its outputs joined into one
# directory, which goes last in LuaRocks' external_deps_dirs. A rock links
# libc libraries such as `m`, `dl`, `pthread` and `rt` by name, and
# LuaRocks' builtin build type looks for each of them there. A Linux
# distribution has them under /usr/lib, which NixOS and the sandbox do not.
{ symlinkJoin, stdenv }:
symlinkJoin {
  name = "luarocks-purifier-libc";
  paths = stdenv.cc.libc.all;
}
