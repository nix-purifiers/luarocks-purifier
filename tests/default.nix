# SPDX-License-Identifier: MIT
#
# The flake's checks: the CLI, the conformance checks of the purifier
# contract, the sandboxed builds of the fixtures under tests/fixtures from
# their committed lockfiles, each with a run of what it built, and the
# real-world project luacheck.
{
  pkgs,
  # The default package overlay of this flake, which adds the scope
  # luarocks-purifier.
  overlay,
  # lib.luarocks-purifier.readLock of this flake.
  readLock,
  cli,
  # The source of luacheck v1.2.0, a flake input of the check partition.
  luacheck,
}:
let
  inherit (pkgs) lib;
  build = (pkgs.extend overlay).luarocks-purifier.buildLuarocksProject;
  contentHash = import ../nix/lib/content-hash.nix;

  # app: a rock with a command, Lua modules, a C dependency (lpeg), a git
  # dependency that links a C library from nixpkgs (lua-zlib with zlib), a
  # zip archive (argparse), a GitHub archive (inspect) and a test suite
  # with a test dependency (luaunit).
  appProject = build { src = ./fixtures/app; };
  app = appProject.packages.app;
  # lib: a LuaJIT project with two rockspecs, where lib-demo depends on
  # lib, a local rocks server (rocks/) with a git source of rockspec format
  # 3.0 (so with submodules), and the two kinds of own source a source rock
  # holds: a release archive that does not exist yet (lib), which the
  # project source stands in for, and an archive pinned by md5 (lib-demo),
  # which the lock holds.
  libProject = build { src = ./fixtures/lib; };
  # vcs: dependencies from Mercurial, Subversion and CVS. Its lockfile is
  # written by hand, and the checkouts come from tests/vcs-checkouts in
  # place of the fetchers, so the check covers how LuaRocks gets each kind
  # of checkout offline. tests/interactive.sh covers how the lock run
  # records them, against local repositories.
  vcs =
    (build {
      src = ./fixtures/vcs;
      fetchers = {
        fetchhg = _: ./vcs-checkouts/hgrock;
        fetchsvn = _: ./vcs-checkouts/svnrock;
        fetchcvs = _: ./vcs-checkouts/cvsrock;
      };
    }).packages.vcs;

  # Lockfiles that the builder must reject, each made from the app
  # fixture's lockfile at evaluation time. `withHash` gives a changed
  # lockfile the content hash that `luarocks-purifier lock` would write, so
  # that the check reaches the problem it is about.
  appLock = builtins.fromJSON (builtins.readFile ./fixtures/app/luarocks-purifier.lock.json);
  withHash = lock: lock // { contentHash = contentHash lock; };
  appWith =
    lock:
    build {
      src = ./fixtures/app;
      lockFile = builtins.toFile "luarocks-purifier.lock.json" (builtins.toJSON lock);
    };
  # The lock in memory holds one problem, whose message names
  # `luarocks-purifier lock`, and evaluating the rock fails.
  rejects =
    name: lock:
    let
      inMemory = readLock {
        src = ./fixtures/app;
        lockFile = builtins.toFile "luarocks-purifier.lock.json" (builtins.toJSON lock);
      };
      problem = builtins.head inMemory.problems;
    in
    assert lib.assertMsg (
      builtins.length inMemory.problems == 1
    ) "the ${name} lockfile does not have one problem";
    assert lib.assertMsg (lib.hasInfix "`luarocks-purifier lock`" problem)
      "the message for the ${name} lockfile does not name `luarocks-purifier lock`: ${problem}";
    assert lib.assertMsg (
      !(builtins.tryEval (appWith lock).packages.app.drvPath).success
    ) "the builder accepted the ${name} lockfile";
    pkgs.runCommand "conformance-${name}" { } ''
      echo ${lib.escapeShellArg problem}
      touch $out
    '';
in
{
  inherit cli;

  # A lockfile made from other rockspecs than the source holds.
  conformance-stale = rejects "stale" (
    withHash (appLock // { definitionHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; })
  );
  # A lockfile with a download hash changed by hand.
  conformance-tampered = rejects "tampered" (
    appLock
    // {
      downloads = map (
        d: if d.path == "server/lpeg-1.1.0-2.src.rock" then d // { hash = lib.fakeHash; } else d
      ) appLock.downloads;
    }
  );
  # Lockfiles that are not valid: one without the fields the builder reads,
  # and one of another format version.
  conformance-malformed =
    pkgs.runCommand "conformance-malformed"
      {
        checks = [
          (rejects "malformed" { version = 3; })
          (rejects "old-format" (withHash (appLock // { version = 0; })))
        ];
      }
      ''
        touch $out
      '';

  # A lockfile that lacks a download (lpeg's source rock): the build fails
  # offline and says to run `luarocks-purifier lock`.
  conformance-missing =
    let
      lock = withHash (
        appLock
        // {
          downloads = builtins.filter (d: d.path != "server/lpeg-1.1.0-2.src.rock") appLock.downloads;
        }
      );
      failure = pkgs.testers.testBuildFailure (appWith lock).packages.app;
    in
    pkgs.runCommand "conformance-missing" { } ''
      grep -q 'run `luarocks-purifier lock`' ${failure}/testBuildFailure.log
      touch $out
    '';

  # The app fixture built from a lockfile kept outside its source, which
  # holds no luarocks-purifier lockfile, and from a source that holds
  # neither lockfile, with luarocks.lock kept outside it too.
  conformance-external =
    let
      withoutLockfiles =
        files:
        lib.fileset.toSource {
          root = ./fixtures/app;
          fileset = lib.fileset.difference ./fixtures/app (lib.fileset.unions files);
        };
      external = build {
        src = withoutLockfiles [ ./fixtures/app/luarocks-purifier.lock.json ];
        lockFile = ./fixtures/app/luarocks-purifier.lock.json;
      };
      externalToolLock = build {
        src = withoutLockfiles [
          ./fixtures/app/luarocks-purifier.lock.json
          ./fixtures/app/luarocks.lock
        ];
        lockFile = ./fixtures/app/luarocks-purifier.lock.json;
        luarocksLock = ./fixtures/app/luarocks.lock;
      };
    in
    pkgs.runCommand "conformance-external" { } ''
      ${external.packages.app.bin.app} "a b a" | grep -q 'a = 2'
      ${externalToolLock.packages.app.bin.app} "a b a" | grep -q 'a = 2'
      touch $out
    '';

  # The unit tests of bin/luarocks-purifier (tests/test_cli.py).
  unit = pkgs.runCommand "luarocks-purifier-unit-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    cp -r ${../bin} bin
    mkdir tests
    cp ${./test_cli.py} tests/test_cli.py
    python3 -m unittest -v tests/test_cli.py
    touch $out
  '';

  inherit app;
  app-tests = appProject.tests;

  # The command the rock installs runs, with its modules and the C modules
  # of its dependencies, and the outputs the lockfile names are where the
  # attributes say. `nix build` reads a package's `outputs` as the list of
  # its derivation outputs, so the builder's attributes must leave it be.
  app-runs =
    assert lib.assertMsg (
      app.outputs == [ "out" ]
    ) "the app package's outputs attribute is not [ \"out\" ]";
    pkgs.runCommand "app-runs" { } ''
      output=$(${app.bin.app} "the cat and The hat")
      echo "$output"
      echo "$output" | grep -q 'the = 2'
      test -f ${app.modules.app}
      test -f ${app.modules."app.words"}
      touch $out
    '';

  # The release holds the source rock, which holds the rockspec and the
  # project source, which stands in for the git tag the rockspec names.
  app-release = pkgs.runCommand "app-release" { nativeBuildInputs = [ pkgs.unzip ]; } ''
    unzip -l ${appProject.release}/app-0.1-1.src.rock | tee listing
    grep -q 'app-0.1-1.rockspec' listing
    grep -q 'src/app/words.lua' listing
    touch $out
  '';

  # The lock in memory of the app fixture has no problems, its entries are
  # the downloads of the lockfile, and `fetches` is those entries.
  app-lock-in-memory =
    let
      inMemory = readLock { src = ./fixtures/app; };
    in
    assert lib.assertMsg (inMemory.problems == [ ]) "the app lock has problems";
    assert lib.assertMsg (inMemory.purifier == "luarocks-purifier") "purifier is not luarocks-purifier";
    assert lib.assertMsg (
      inMemory.entries == appLock.downloads
    ) "entries is not the downloads of the lockfile";
    assert lib.assertMsg (
      inMemory.outputs.app.bin == [ "app" ]
    ) "the outputs of app do not list its command";
    assert lib.assertMsg (
      appProject.fetches == inMemory.entries
    ) "fetches is not the entries of the lock";
    pkgs.runCommand "app-lock-in-memory" { } "touch $out";

  # `luarocks upload`, as `luarocks-purifier publish` runs it, sends the
  # rockspec and the source rock Nix packed, byte for byte, to a stand-in
  # for the luarocks.org upload API.
  app-publish =
    pkgs.runCommand "app-publish"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.curl
          app.luarocks
        ];
      }
      ''
        export HOME=$TMPDIR/home LUA_INIT=@${../nix/lib/tmpname.lua}
        mkdir -p $HOME
        # luarocks upload writes upload_config.lua beside the configuration,
        # which a build outside the sandbox could then write into /nix/store.
        cp ${../nix/lib/publish-config.lua} $HOME/config.lua
        export LUAROCKS_CONFIG=$HOME/config.lua
        python3 ${./fake-luarocks-server.py} $TMPDIR/uploads $TMPDIR/port &
        # Darwin builds have no PID namespace, so a server left running
        # would keep the build's log open after the builder exits.
        server=$!
        trap 'kill $server' EXIT
        while [ ! -f $TMPDIR/port ]; do sleep 0.1; done
        cp -r ${./fixtures/app} src
        cd src
        luarocks upload app-0.1-1.rockspec ${appProject.release}/app-0.1-1.src.rock \
          --server "http://127.0.0.1:$(cat $TMPDIR/port)" --api-key test
        cmp $TMPDIR/uploads/app-0.1-1.rockspec app-0.1-1.rockspec
        cmp $TMPDIR/uploads/app-0.1-1.src.rock ${appProject.release}/app-0.1-1.src.rock
        touch $out
      '';

  lib = libProject.packages.lib;
  lib-demo = libProject.packages.lib-demo;

  lib-runs = pkgs.runCommand "lib-runs" { } ''
    output=$(${libProject.packages.lib-demo.bin.lib-demo})
    echo "$output"
    echo "$output" | grep -q 'LuaJIT'
    test -f ${libProject.packages.lib.modules.lib}
    touch $out
  '';

  lib-release = pkgs.runCommand "lib-release" { nativeBuildInputs = [ pkgs.unzip ]; } ''
    unzip -l ${libProject.release}/lib-1.0-1.src.rock | tee lib
    grep -q 'lib-1.0.tar.gz' lib
    unzip -p ${libProject.release}/lib-1.0-1.src.rock lib-1.0.tar.gz | tar -tzf - > archive-files
    grep -Fx 'lib-1.0/src/lib.lua' archive-files
    unzip -l ${libProject.release}/lib-demo-1.0-1.src.rock | tee demo
    grep -q '0.7.1.zip' demo
    touch $out
  '';

  vcs-runs = pkgs.runCommand "vcs-runs" { } ''
    LUA_PATH='${vcs}/share/lua/5.4/?.lua' ${vcs.lua}/bin/lua -e '
      local s = require("vcs").sources
      assert(s[1] == "mercurial" and s[2] == "subversion" and s[3] == "cvs")
    '
    touch $out
  '';

  # luacheck v1.2.0, unchanged, from the lockfile in tests/real/luacheck,
  # checks its own source and finds nothing.
  real-luacheck =
    let
      luacheckPackage =
        (build {
          src = luacheck;
          lockFile = ./real/luacheck/luarocks-purifier.lock.json;
        }).packages.luacheck;
    in
    pkgs.runCommand "real-luacheck" { } ''
      ${luacheckPackage.bin.luacheck} --version | grep -q 'Luacheck: 1.2.0'
      cd ${luacheck}
      ${luacheckPackage.bin.luacheck} --no-cache --no-color src | tee $TMPDIR/report
      grep -q '0 warnings / 0 errors' $TMPDIR/report
      touch $out
    '';
}
