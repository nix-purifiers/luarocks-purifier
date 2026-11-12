# SPDX-License-Identifier: MIT
#
# The tool stand-ins LuaRocks runs instead of curl, git, hg, svn and cvs:
# bin/luarocks-purifier-<tool>, each the luarocks-purifier script on
# Python's standard library. In the lock run they run the real tool and log
# what it fetched; offline they serve the locked files and checkouts (see
# bin/luarocks-purifier). They hold no tool themselves, so the sandboxed
# build depends on Python alone for them.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3Minimal,
}:
stdenvNoCC.mkDerivation {
  pname = "luarocks-purifier-shims";
  version = import ../version.nix;
  src = ../../bin;
  nativeBuildInputs = [ makeWrapper ];
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    install -Dm644 luarocks-purifier "$out/libexec/luarocks-purifier.py"
    for tool in curl git hg svn cvs sscm; do
      makeWrapper ${python3Minimal}/bin/python3 "$out/bin/luarocks-purifier-$tool" \
        --add-flags "$out/libexec/luarocks-purifier.py --tool=$tool"
    done
    runHook postInstall
  '';
  meta = {
    description = "The tool stand-ins with which luarocks-purifier records and serves LuaRocks downloads";
    license = lib.licenses.mit;
  };
}
