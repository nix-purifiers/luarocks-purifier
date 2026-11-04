# SPDX-License-Identifier: MIT
{
  system ? builtins.currentSystem,
}:
let
  f = builtins.getFlake (toString ../.);
  pkgs = import f.inputs.nixpkgs { inherit system; };
  package =
    name:
    builtins.derivation {
      inherit name system;
      outputs = [
        "out"
        "secondary"
      ];
      builder = "/sdk-must-remain-unbuilt";
    };
  runtime = package "runtime-must-remain-unbuilt";
  manager = package "manager-must-remain-unbuilt";
  matrix = {
    target = {
      lua = runtime.secondary // {
        outputSpecified = true;
      };
      luarocks = manager;
      luaVersion = "1";
      luarocksVersion = "2";
      luaExecutable = "lua";
    };
  };
in
{
  carrier = pkgs.writeText "sdk-matrix.nix" (import ../nix/lib/sdk-matrix-expression.nix matrix);
  descriptors = map builtins.unsafeDiscardStringContext [
    runtime.drvPath
    manager.drvPath
  ];
  outputs = map builtins.unsafeDiscardStringContext [
    runtime.secondary.outPath
    manager.outPath
  ];
}
