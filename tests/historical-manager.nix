# SPDX-License-Identifier: MIT
# The historical distribution pins the 2.2.0-rc1 source archive even though
# its derivation and native --version report 2.2.0. Keep that provenance.
{ pkgs, cli }:
let
  source = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/770822493e3962d795739fafd522e771bfe06e3d.tar.gz";
    sha256 = "sha256-rw241C89ocMlDTYP9c2fAb06Yf4Khpjy5PRnoPEb/qQ=";
  };
  old = import source {
    system = "x86_64-linux";
    config = { };
  };
  manager = old.lib.overrideDerivation old.lua51Packages.luarocks (_: {
    src = pkgs.fetchurl {
      url = "https://luarocks.org/releases/luarocks-2.2.0-rc1.tar.gz";
      sha256 = "1717p694455w1fdldb2ldlyklln8w3bqk1dsly8gpqh3n73lw6lv";
    };
  });
  sdk = pkgs.lua5_1 // {
    pkgs = pkgs.lua5_1.pkgs // {
      luarocks = manager;
    };
  };
in
cli.override {
  pkgs = pkgs // {
    lua5_1 = sdk;
  };
}
