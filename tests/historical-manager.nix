# SPDX-License-Identifier: MIT
# The historical distribution pins the 2.2.0-rc1 source archive even though
# its derivation and native --version report 2.2.0. Keep that provenance.
{ pkgs, scope }:
let
  source = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/770822493e3962d795739fafd522e771bfe06e3d.tar.gz";
    sha256 = "sha256-rw241C89ocMlDTYP9c2fAb06Yf4Khpjy5PRnoPEb/qQ=";
  };
  old = import source {
    system = "x86_64-linux";
    config = { };
  };
  nativeManager = old.lib.overrideDerivation old.lua51Packages.luarocks (_: {
    src = pkgs.fetchurl {
      url = "https://luarocks.org/releases/luarocks-2.2.0-rc1.tar.gz";
      sha256 = "1717p694455w1fdldb2ldlyklln8w3bqk1dsly8gpqh3n73lw6lv";
    };
  });
  manager =
    pkgs.runCommand "luarocks-2.2.0-with-json"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        passthru.version = nativeManager.version;
      }
      ''
        mkdir -p "$out/bin"
        for program in luarocks luarocks-admin; do
          makeWrapper ${nativeManager}/bin/$program "$out/bin/$program" \
            --prefix LUA_PATH ';' '${pkgs.lua51Packages.dkjson}/share/lua/5.1/?.lua'
        done
      '';

in
(scope.overrideScope (
  _: previous: {
    luaSDKs = previous.luaSDKs // {
      "5.1" = {
        lua = pkgs.lua5_1;
        luarocks = manager;
      };
    };
  }
)).cli
