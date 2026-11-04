# SPDX-License-Identifier: MIT
# Preserve both original recipes. Metadata stays outside the restored derivations.
sdks:
let
  quote = input: builtins.replaceStrings [ "\${" ] [ "\\\${" ] (builtins.toJSON input);
  entries = map (
    name:
    let
      sdk = sdks.${name};
      executable = sdk.luaExecutable or (if name == "luajit" then "luajit" else "lua");
      luaVersion = sdk.luaVersion or (sdk.lua.version or (builtins.parseDrvName sdk.lua.name).version);
      managerVersion =
        sdk.luarocksVersion or (sdk.luarocks.version or (builtins.parseDrvName sdk.luarocks.name).version);
    in
    "${quote name} = { lua = ${(import ./sdk-expression.nix sdk.lua).expression}; luarocks = ${(import ./sdk-expression.nix sdk.luarocks).expression}; luaExecutable = ${quote executable}; luaVersion = ${quote luaVersion}; luarocksVersion = ${quote managerVersion}; };"
  ) (builtins.attrNames sdks);
in
"{ ${builtins.concatStringsSep " " entries} }"
