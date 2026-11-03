#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The tests of what runs outside the Nix sandbox. CI runs each section as a
# job of the same name:
#
#   conformance-relock   the lock run of each fixture reproduces its
#                        committed lockfile byte for byte
#   conformance-update   `update` of a rock that luarocks.lock pins to an old
#                        version moves both lockfiles, which then pass the
#                        stale check
#   conformance-rebuild  `nix build --rebuild` of the app fixture gives the
#                        same output
#   conformance-offline  after `luarocks-purifier prefetch`, the everyday
#                        loop of the app fixture (make, run, test) works
#                        with the network cut off
#   interactive          the interactive mode: make, a rock missing from the
#                        lockfile, an edited lockfile, a stale lockfile and a
#                        lockfile outside the project, each stopping with a
#                        message that names `luarocks-purifier lock`
#   vcs                  the lock run records Mercurial, Subversion and CVS
#                        sources from local repositories, and refuses a
#                        Surround SCM source
#   publish              `luarocks-purifier publish` uploads the release that
#                        Nix built to a stand-in for the luarocks.org API
#   real-luacheck        luacheck v1.2.0 with its whole test suite: lock,
#                        the sandboxed tests, prefetch, and `luarocks test`
#                        with the network cut off
#
# Run it from the repository root: tests/interactive.sh [SECTION...], where
# no section means all of them.
set -euo pipefail

repo=$(pwd)
# macOS sets TMPDIR with a trailing slash, and a path with "//" in it is not
# a Nix path.
tmp=${TMPDIR:-/tmp}
work=$(mktemp -d "${tmp%/}/luarocks-purifier-test.XXXXXX")
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
system=$(nix eval --raw --impure --expr builtins.currentSystem)

tool() {
  nix build --no-link --print-out-paths "nixpkgs#$1" | tail -1
}

nix build --out-link "$work/cli" "$repo#cli"
cli=$work/cli/bin/luarocks-purifier
for t in mercurial subversion cvs python3 gitMinimal lua5_4 lua5_4.pkgs.luarocks binutils util-linux; do
  dir=$(tool "$t")
  PATH=$dir/bin:$PATH
done
export PATH
export HOME=$work/home XDG_CONFIG_HOME=$work/home/.config
mkdir -p "$HOME"

step() {
  echo "== $*"
}

# Runs a command with the network cut off: in a network namespace of its
# own, which an unprivileged user namespace allows, or else sudo (as on the
# GitHub runners, which restrict unprivileged user namespaces).
offline() {
  if unshare -rn true 2>/dev/null; then
    unshare -rn -- "$@"
  elif sudo -n true 2>/dev/null; then
    sudo -n unshare -n -- sudo -n -u "$(id -un)" env "PATH=$PATH" "HOME=$HOME" "TMPDIR=${TMPDIR:-/tmp}" "$@"
  else
    echo "cannot cut the network: no unprivileged user namespace and no sudo"
    return 1
  fi
}

# A copy of a fixture without what a local run leaves behind (both are in
# .gitignore).
fixture() {
  cp -r "$repo/tests/fixtures/$1" "$work/$2"
  rm -rf "$work/$2/lua_modules" "$work/$2/.luarocks-purifier"
}

conformance-relock() {
  for f in app lib; do
    step "relock $f"
    fixture "$f" "relock-$f"
    (cd "$work/relock-$f" && "$cli" lock)
    cmp "$repo/tests/fixtures/$f/luarocks-purifier.lock.json" "$work/relock-$f/luarocks-purifier.lock.json"
  done
}

conformance-update() {
  step "update a pinned old version"
  fixture app update
  cd "$work/update"
  # argparse may be any version from 0.7.1, and luarocks.lock pins the
  # older of the two that luarocks.org serves for Lua 5.4. The backup
  # suffix makes -i work with the BSD sed of macOS too.
  sed -i.orig 's/"argparse == 0.7.1"/"argparse >= 0.7.1"/' app-0.1-1.rockspec
  rm app-0.1-1.rockspec.orig
  cat > luarocks.lock <<'EOF'
return {
   dependencies = {
      ["argparse"] = "0.7.1-1",
   },
}
EOF
  # `lock` keeps the pin.
  "$cli" lock
  grep -q '"server/argparse-0.7.1-1.src.rock"' luarocks-purifier.lock.json
  # `update argparse` resolves it again, and both lockfiles move.
  "$cli" update argparse
  grep -q '"argparse"\] = "0.7.2-1"' luarocks.lock
  grep -q '"server/argparse-0.7.2-1.src.rock"' luarocks-purifier.lock.json
  if grep -q 'argparse-0.7.1-1' luarocks-purifier.lock.json; then
    echo "the lockfile still holds argparse 0.7.1-1"
    exit 1
  fi
  # Both lockfiles pass the stale check, in the command and at evaluation.
  "$cli" luarocks --version > /dev/null
  nix eval --impure --expr "
    let
      flake = builtins.getFlake \"git+file://$repo\";
      inMemory = flake.lib.luarocks-purifier.readLock { src = $work/update; };
    in
    assert inMemory.problems == [ ]; true" > /dev/null
  cd "$repo"
}

conformance-rebuild() {
  step "rebuild app"
  nix build --no-link "$repo#checks.$system.app"
  nix build --no-link --rebuild "$repo#checks.$system.app"
}

conformance-offline() {
  step "prefetch, then the everyday loop offline"
  fixture app offline
  cd "$work/offline"
  "$cli" prefetch
  # The editor finds the dependencies in lua_modules right after prefetch.
  test -f lua_modules/share/lua/5.4/inspect.lua
  # Collect garbage first: what prefetch realized has GC roots, so the
  # offline loop finds it all.
  nix-store --gc > /dev/null
  offline "$cli" luarocks make
  offline lua_modules/bin/app "the cat and the hat" | grep -q 'the = 2'
  offline "$cli" luarocks test
  cd "$repo"
}

interactive() {
  step "interactive make"
  fixture app app
  (
    cd "$work/app"
    "$cli" luarocks make 2>&1 | tee make.log
    # LuaRocks names each rock it installs. Nix may fetch the locked files
    # from luarocks.org while it builds the offline cache, but LuaRocks
    # installs every rock from that cache.
    grep -q 'Installing .*luarocks-purifier-cache/server' make.log
    if grep 'Installing ' make.log | grep -qv 'luarocks-purifier-cache/server'; then
      echo "the interactive make installed a rock from outside the offline cache"
      exit 1
    fi
    # The C module records where its C library is, whichever compiler built
    # it, so it loads outside the shell of the lock run. Linux records the
    # directory in the RPATH; macOS records the library by its full path,
    # which for a nixpkgs library is in the Nix store.
    if [ "$(uname)" = Darwin ]; then
      objdump -P load lua_modules/lib/lua/5.4/zlib.so | grep -q 'name: /nix/store/.*/libz'
    else
      readelf -d lua_modules/lib/lua/5.4/zlib.so | grep -E 'R(UN)?PATH' | grep -q luarocks-purifier-external
    fi
    output=$(lua_modules/bin/app "the cat and the hat")
    echo "$output" | grep -q 'the = 2'
  )

  step "a rock missing from the lockfile"
  (
    cd "$work/app"
    if "$cli" luarocks install penlight > missing.log 2>&1; then
      echo "an offline install of a rock outside the lockfile succeeded"
      exit 1
    fi
    # shellcheck disable=SC2016 # the backticks are part of the message
    grep -q 'run `luarocks-purifier lock`' missing.log
  )

  step "an edited lockfile"
  fixture app tampered
  (
    cd "$work/tampered"
    python3 - <<'EOF'
import json
lock = json.load(open("luarocks-purifier.lock.json"))
entry = next(d for d in lock["downloads"] if d["path"].startswith("server/"))
entry["hash"] = "sha256-" + "B" * 43 + "="
json.dump(lock, open("luarocks-purifier.lock.json", "w"), indent=2, sort_keys=True)
EOF
    if "$cli" luarocks make > tampered.log 2>&1; then
      echo "the interactive mode accepted an edited lockfile"
      exit 1
    fi
    grep -q 'contentHash does not match' tampered.log
    # shellcheck disable=SC2016 # the backticks are part of the message
    grep -q '`luarocks-purifier lock`' tampered.log
  )

  step "a stale lockfile"
  fixture app stale
  (
    cd "$work/stale"
    echo "-- changed" >> app-0.1-1.rockspec
    if "$cli" luarocks --version > stale.log 2>&1; then
      echo "the interactive mode ran with a stale lockfile"
      exit 1
    fi
    grep -q 'out of date' stale.log
    # shellcheck disable=SC2016 # the backticks are part of the message
    grep -q '`luarocks-purifier lock`' stale.log
  )

  step "a lockfile outside the project"
  fixture app external
  (
    cd "$work/external"
    mv luarocks-purifier.lock.json "$work/external.lock.json"
    "$cli" luarocks --lockfile "$work/external.lock.json" make > external.log 2>&1
    lua_modules/bin/app "a b a" | grep -q 'a = 2'
    "$cli" lock --lockfile "$work/external.lock.json"
    test ! -e luarocks-purifier.lock.json
    cmp "$repo/tests/fixtures/app/luarocks-purifier.lock.json" "$work/external.lock.json"
  )

  step "a luarocks.lock outside the project"
  fixture app toollock
  (
    cd "$work/toollock"
    mv luarocks-purifier.lock.json "$work/toollock.lock.json"
    cp luarocks.lock "$work/tree-copy.lock"
    mkdir "$work/outside"
    # `update` writes luarocks.lock at the path it is given, starting from
    # the copy in the project, and leaves that copy as it is.
    "$cli" update --lockfile "$work/toollock.lock.json" --tool-lockfile "$work/outside/luarocks.lock"
    cmp luarocks.lock "$work/tree-copy.lock"
    test -s "$work/outside/luarocks.lock"
    # The lockfiles are current for the project and the outside copy, even
    # once the copy in the project differs.
    echo "-- changed" >> luarocks.lock
    "$cli" luarocks --lockfile "$work/toollock.lock.json" --tool-lockfile "$work/outside/luarocks.lock" --version > /dev/null
    # The environment variables name the same paths.
    LUAROCKS_PURIFIER_LOCKFILE="$work/toollock.lock.json" LUAROCKS_PURIFIER_TOOL_LOCKFILE="$work/outside/luarocks.lock" \
      "$cli" luarocks --version > /dev/null
  )
}

vcs() {
  step "lock run of Mercurial, Subversion and CVS sources"
  local vcs=$work/vcs-repos
  mkdir -p "$vcs"
  # nixpkgs' CVS aborts (SIGABRT, and at times SIGSEGV on aarch64-darwin,
  # whose `uname -m` is arm64) on a tagged export on aarch64-linux and
  # aarch64-darwin, so the lock run cannot export a CVS source there (see
  # the README). The vcs-runs flake check covers how a CVS checkout is
  # served on every system.
  local rocks="hgrock svnrock cvsrock"
  case $(uname -m) in
    aarch64 | arm64)
      rocks="hgrock svnrock"
      echo "skipping the CVS source: nixpkgs' CVS aborts on aarch64"
      ;;
  esac
  (
    # A Mercurial repository with the tag 1.0.
    mkdir "$vcs/hgrock" && cd "$vcs/hgrock"
    hg init -q
    echo 'return "mercurial"' > hgrock.lua
    hg add -q hgrock.lua
    hg commit -q -m init -u test
    hg tag -q -u test 1.0
  )
  (
    # A Subversion repository at revision 1.
    svnadmin create "$vcs/svnrepo"
    svn checkout -q "file://$vcs/svnrepo" "$vcs/svnwc"
    cd "$vcs/svnwc"
    echo 'return "subversion"' > svnrock.lua
    svn add -q svnrock.lua
    svn commit -q -m init
  )
  case $rocks in
    *cvsrock*)
      (
        # A CVS module with the tag REL_1_0.
        cvs -d "$vcs/cvsroot" init
        mkdir "$vcs/cvsimport" && cd "$vcs/cvsimport"
        echo 'return "cvs"' > cvsrock.lua
        cvs -Q -d "$vcs/cvsroot" import -m init cvsrock vendor start
        cd "$vcs" && cvs -Q -d "$vcs/cvsroot" rtag REL_1_0 cvsrock
      )
      (
        # The tagged export the lock run makes, run here first so that a
        # failure shows what CVS reports.
        mkdir "$vcs/probe" && cd "$vcs/probe"
        cvs -d "$vcs/cvsroot" export -r REL_1_0 cvsrock
        test -f cvsrock/cvsrock.lua
      )
      ;;
  esac
  local project=$work/vcs-project
  mkdir -p "$project/rocks"
  local dependencies='"lua >= 5.1"'
  local requires=""
  local rock source
  for rock in $rocks; do
    dependencies="$dependencies, \"$rock == 1.0\""
    requires="$requires require(\"$rock\"),"
    case $rock in
      hgrock) source="url = \"hg://file://$vcs/hgrock\", tag = \"1.0\"" ;;
      svnrock) source="url = \"svn://file://$vcs/svnrepo\", tag = \"1\"" ;;
      cvsrock) source="url = \"cvs://$vcs/cvsroot\", module = \"cvsrock\", tag = \"REL_1_0\"" ;;
    esac
    cat > "$project/rocks/$rock-1.0-1.rockspec" <<EOF
package = "$rock"
version = "1.0-1"
source = { $source }
dependencies = { "lua >= 5.1" }
build = { type = "builtin", modules = { $rock = "$rock.lua" } }
EOF
  done
  cat > "$project/vcs-1.0-1.rockspec" <<EOF
package = "vcs"
version = "1.0-1"
source = { url = "git+https://example.org/vcs.git" }
dependencies = { $dependencies }
build = { type = "builtin", modules = { vcs = "vcs.lua" } }
EOF
  echo "return {$requires }" > "$project/vcs.lua"
  LUA_INIT=@$repo/nix/lib/tmpname.lua luarocks-admin make_manifest "$project/rocks"
  (
    cd "$project"
    "$cli" lock --only-server ./rocks
    # The kinds of checkout the lock must hold: hg, svn, and cvs when the
    # CVS source is part of the test.
    expected=$(for rock in $rocks; do echo "${rock%rock}"; done | sort | tr '\n' ' ')
    EXPECTED=$expected python3 - <<'EOF'
import json, os
expected = set(os.environ["EXPECTED"].split())
lock = json.load(open("luarocks-purifier.lock.json"))
kinds = {k for d in lock["downloads"] for k in ("hg", "svn", "cvs") if k in d}
assert kinds == expected, kinds
for d in lock["downloads"]:
    assert d["hash"].startswith("sha256-"), d
by_path = {d["path"]: d for d in lock["downloads"]}
assert {k for c in lock["checkouts"] for k in ("hg", "svn", "cvs") if k in by_path[c["path"]]} == expected
print("recorded", sorted(kinds))
EOF
  )

  step "a Surround SCM source"
  (
    sscm=$work/sscm-project
    mkdir -p "$sscm/rocks"
    cat > "$sscm/rocks/sscmrock-1.0-1.rockspec" <<'EOF'
package = "sscmrock"
version = "1.0-1"
source = { url = "sscm://sscm.example.org/repo", branch = "main" }
dependencies = { "lua >= 5.1" }
build = { type = "builtin", modules = { sscmrock = "sscmrock.lua" } }
EOF
    cat > "$sscm/uses-sscm-1.0-1.rockspec" <<'EOF'
package = "uses-sscm"
version = "1.0-1"
source = { url = "git+https://example.org/uses-sscm.git" }
dependencies = { "lua >= 5.1", "sscmrock == 1.0" }
build = { type = "builtin", modules = {} }
EOF
    LUA_INIT=@$repo/nix/lib/tmpname.lua luarocks-admin make_manifest "$sscm/rocks"
    cd "$sscm"
    if "$cli" lock --only-server ./rocks > sscm.log 2>&1; then
      echo "the lock run accepted a Surround SCM source"
      exit 1
    fi
    grep -q 'Surround SCM' sscm.log
  )
}

publish() {
  step "publish"
  fixture lib publish
  (
    cd "$work/publish"
    python3 "$repo/tests/fake-luarocks-server.py" "$work/uploads" "$work/port" &
    server=$!
    trap 'kill $server' EXIT
    while [ ! -f "$work/port" ]; do sleep 0.1; done
    "$cli" publish lib-1.0-1.rockspec --server "http://127.0.0.1:$(cat "$work/port")" --api-key test
    cmp "$work/uploads/lib-1.0-1.rockspec" lib-1.0-1.rockspec
    test -s "$work/uploads/lib-1.0-1.src.rock"
    # LuaRocks saved the API key where a plain `luarocks upload` finds it.
    grep -q 'test' "$HOME/.luarocks/upload_config.lua"
  )
}

real-luacheck() {
  step "luacheck v1.2.0 with its whole test suite"
  local rev=cc089e3f65acdd1ef8716cc73a3eca24a6b845e4
  mkdir "$work/luacheck"
  curl -fsSL "https://codeload.github.com/lunarmodules/luacheck/tar.gz/$rev" | tar -xz -C "$work/luacheck" --strip-components 1
  cd "$work/luacheck"
  # luacheck's own CI installs three test dependencies by hand; a project
  # that uses luarocks-purifier declares them in the rockspec.
  python3 - <<'EOF'
p = "luacheck-dev-1.rockspec"
s = open(p).read()
s = s.replace('   "busted",\n}', '   "busted",\n   "lanes",\n   "luautf8",\n   "luasocket",\n}')
open(p, "w").write(s)
EOF
  "$cli" lock
  nix build --no-link --impure --expr "
    let
      flake = builtins.getFlake \"git+file://$repo\";
      pkgs = import flake.inputs.nixpkgs {
        system = \"$system\";
        overlays = [ flake.overlays.default ];
      };
    in
    (pkgs.luarocks-purifier.buildLuarocksProject { src = $work/luacheck; }).tests"
  "$cli" prefetch
  offline "$cli" luarocks make
  offline "$cli" luarocks test 2>&1 | tee test.log
  grep -q '0 failures / 0 errors' test.log
  cd "$repo"
}

sections=("$@")
if [ ${#sections[@]} -eq 0 ]; then
  sections=(conformance-relock conformance-update conformance-rebuild conformance-offline interactive vcs publish real-luacheck)
fi
for section in "${sections[@]}"; do
  "$section"
done

echo "all interactive tests passed: ${sections[*]}"
