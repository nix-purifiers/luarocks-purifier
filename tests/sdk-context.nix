# SPDX-License-Identifier: MIT
{
  system ? builtins.currentSystem,
}:
let
  f = builtins.getFlake (toString ../.);
  pkgs = import f.inputs.nixpkgs { inherit system; };
  package =
    name:
    pkgs.runCommand name {
      outputs = [
        "out"
        "secondary"
      ];
    } "exit 1";
  runtime = package "unbuildable-runtime";
  manager = package "unbuildable-manager";
  original = {
    target = {
      lua = runtime.secondary;
      luarocks = manager;
      luaVersion = "1";
      luarocksVersion = "2";
      luaExecutable = "lua";
    };
  };
  expression = import ../nix/lib/sdk-matrix-expression.nix original;
  restored = import (
    builtins.toFile "restored-lua-sdk-matrix.nix" (builtins.unsafeDiscardStringContext expression)
  );
  consume = sdk: pkgs.runCommand "sdk-context-consumer" { buildInputs = [ sdk ]; } "touch $out";
in
assert (consume original.target.lua).drvPath == (consume restored.target.lua).drvPath;
assert (consume original.target.luarocks).drvPath == (consume restored.target.luarocks).drvPath;
assert
  builtins.getContext (toString original.target.lua)
  == builtins.getContext (toString restored.target.lua);
assert
  builtins.getContext (toString original.target.luarocks)
  == builtins.getContext (toString restored.target.luarocks);
assert restored.target.luaExecutable == "lua";
assert restored.target.luaVersion == "1";
assert restored.target.luarocksVersion == "2";
{
  inherit system;
  runtimeDerivation = restored.target.lua.drvPath;
  managerDerivation = restored.target.luarocks.drvPath;
  selectedOutput = restored.target.lua.outputName;
  noSdkBuildRequired = true;
}
