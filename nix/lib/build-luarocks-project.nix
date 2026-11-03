# SPDX-License-Identifier: MIT
#
# buildLuarocksProject: builds the rocks of a LuaRocks project offline in
# the Nix sandbox, from its luarocks-purifier lockfile.
#
# The file is a package for callPackage: the first argument set is what it
# takes from the scope, and the result is the builder. The overlay
# `overlays.default` of this flake adds the scope `luarocks-purifier`, which
# holds the builder, so a package written for callPackage takes the scope by
# name:
#
#   { luarocks-purifier }:
#   (luarocks-purifier.buildLuarocksProject { src = ./.; }).packages.app
#
# `luarocks-purifier.buildLuarocksProject.override` replaces what the
# builder takes, and `luarocks-purifier.overrideScope` replaces what the
# scope shares.
#
# The builder's arguments:
#
#   src           the project root
#   lockFile      the lockfile; the default is src's
#                 luarocks-purifier.lock.json. A lockfile outside src
#                 replaces any copy in it.
#   luarocksLock  LuaRocks' own lockfile (luarocks.lock); the default is the
#                 copy in src. A copy kept outside src takes its place.
#   externalDeps  the C libraries the rocks need, as a list of packages; the
#                 default is the nixpkgs attributes the lockfile names
#   fetchers      fetchers that replace those of nixpkgs for the locked
#                 downloads, by name (fetchurl, fetchgit, fetchhg, fetchsvn,
#                 fetchcvs), for credentials or a company mirror; the shared
#                 library's fetchEntry calls each with the arguments of the
#                 nixpkgs fetcher of the same name
#
# The result:
#
#   packages.<package>  the rock that a rockspec of the project defines,
#                       installed with its dependencies into a LuaRocks tree
#                       (bin/, share/lua/, lib/lua/ and lib/luarocks/), with
#                       the attributes .bin.<command> and .modules.<module>
#                       (such as "foo.bar"), which the lockfile names, so
#                       they are known without building
#   tests               `luarocks test` of every rockspec that has a test
#                       suite, in the sandbox
#   release             the source rocks that `luarocks-purifier publish`
#                       uploads, packed in the sandbox: a directory holding
#                       <package>-<version>.src.rock for each rockspec
#   fetches             the download entries of the lockfile, in the shape
#                       of the shared purifier library
{
  lib,
  stdenv,
  # The package set, from which the lockfile names C libraries and the Lua
  # of the build (see lua.nix).
  pkgs,
  callPackage,
  runCommand,
  linkFarm,
  symlinkJoin,
  writeText,
  # The fetchers for the locked downloads, and the packages that
  # `fetchEntry` of the shared library unpacks and checks them with.
  fetchurl,
  fetchgit,
  fetchhg,
  fetchsvn,
  fetchcvs,
  unzip,
  zstd,
  python3,
  zip,
  gnutar,
  gzip,
  bzip2,
  xz,
  cmake,
  gnumake,
  # The tool stand-ins that LuaRocks runs in place of curl, git and the
  # other fetching tools (pkgs/shims).
  shims,
  # The `purifier` namespace of the shared nix-purifiers library, which the
  # default package overlay gives.
  purifier ? throw "luarocks-purifier: the builder needs `purifier`, which the default package overlay of this flake gives",
}:
{
  src,
  lockFile ? src + "/luarocks-purifier.lock.json",
  luarocksLock ? null,
  externalDeps ? null,
  fetchers ? { },
}:
let
  luarocks-purifier-shims = shims;

  cache = callPackage ./cache.nix {
    projectSource = cleanSource;
    inherit
      lockFile
      luarocksLock
      externalDeps
      purifier
      fetchers
      fetchurl
      fetchgit
      fetchhg
      fetchsvn
      fetchcvs
      runCommand
      unzip
      zstd
      python3
      writeText
      ;
  };
  inherit (cache) lock luarocks externals;
  lua = (import ./lua.nix { inherit pkgs; }).${lock.lua};
  abi = lock.luaAbi;

  # The project source, without the files of a local run and without the
  # lockfile, which the build reads from lockFile.
  cleanSource = lib.cleanSourceWith {
    name = "source";
    src = lib.cleanSource src;
    filter =
      path: _type:
      !(builtins.elem (baseNameOf path) [
        ".luarocks-purifier"
        "lua_modules"
        "luarocks-purifier.lock.json"
      ]);
  };
  source =
    if luarocksLock == null then
      cleanSource
    else
      runCommand "source" { } ''
        cp -r ${cleanSource} $out
        chmod -R u+w $out
        cp ${luarocksLock} $out/luarocks.lock
      '';

  luaString = s: builtins.toJSON s;

  # The rocks servers as LuaRocks searches them offline: a local server (a
  # directory of the project) in the project source, and the locked files
  # of every remote server in the cache.
  servers = lib.unique (
    map (
      group:
      let
        first = builtins.head group;
      in
      if builtins.match "[a-z][a-z0-9+.-]*://.*" first != null then
        "${cache}/server"
      else
        "${source}/${first}"
    ) lock.servers
  );

  infosByFile = builtins.listToAttrs (
    map (info: {
      name = info.file;
      value = info;
    }) lock.rockspecs
  );

  # The project rockspecs a rockspec depends on, each after its own, as
  # `luarocks make` installs them before the rockspec itself.
  projectDependencies =
    info:
    lib.unique (
      lib.concatMap (file: projectDependencies infosByFile.${file} ++ [ file ]) (
        info.projectDependencies or [ ]
      )
    );

  # LuaRocks compiles and links C code with CC, which stdenv sets to its
  # compiler, except on macOS, where it runs `gcc` whatever CC says, and the
  # darwin stdenv has no gcc.
  darwinVariables = lib.optionalString stdenv.hostPlatform.isDarwin ''
    CC = "$CC",
    LD = "$CC",
  '';

  # The LuaRocks configuration of a sandboxed run, with the tree and the
  # rocks servers given as shell words.
  writeConfig = ''
    writeConfig() {
      cat > "$1" <<EOF
    fs_use_modules = false
    check_certificates = true
    local_cache = "$TMPDIR/luarocks-local-cache"
    rocks_trees = { $2 }
    rocks_servers = { ${lib.concatMapStringsSep ", " luaString servers} }
    external_deps_dirs = { ${
      lib.concatMapStringsSep ", " (d: luaString "${d}") (externals ++ [ cache.libc ])
    } }
    variables = {
      WGET = "/nonexistent/wget",
      CURL = "${luarocks-purifier-shims}/bin/luarocks-purifier-curl",
      GIT = "${luarocks-purifier-shims}/bin/luarocks-purifier-git",
      HG = "${luarocks-purifier-shims}/bin/luarocks-purifier-hg",
      SVN = "${luarocks-purifier-shims}/bin/luarocks-purifier-svn",
      CVS = "${luarocks-purifier-shims}/bin/luarocks-purifier-cvs",
      SSCM = "${luarocks-purifier-shims}/bin/luarocks-purifier-sscm",
    ${darwinVariables}}
    EOF
    }
    export HOME=$TMPDIR/home
    mkdir -p "$HOME"
    export LUA_INIT=@${./tmpname.lua}
    export LUAROCKS_PURIFIER_MODE=serve
    export LUAROCKS_PURIFIER_CACHE=${cache}
  '';

  nativeTools = [
    luarocks
    lua
    luarocks-purifier-shims
  ]
  ++ [
    unzip
    zip
    gnutar
    gzip
    bzip2
    xz
    cmake
    gnumake
  ];

  # How LuaRocks requests the rockspec's own source, which the source rock
  # holds: the tool it runs and the URL it passes (LuaRocks drops a "git+"
  # or "hg+" prefix and an "hg://" or "svn://" scheme), or a download.
  selfRequest =
    info:
    let
      s = info.source;
      url = s.url or "";
      has = lib.hasPrefix;
      basename = baseNameOf url;
    in
    if has "git+file://" url then
      {
        kind = "git";
        url = lib.removePrefix "git+file://" url;
      }
    else if has "git+" url then
      {
        kind = "git";
        url = lib.removePrefix "git+" url;
      }
    else if has "git://" url then
      {
        kind = "git";
        inherit url;
      }
    else if has "hg+" url then
      {
        kind = "hg";
        url = lib.removePrefix "hg+" url;
      }
    else if has "hg://" url then
      {
        kind = "hg";
        url = lib.removePrefix "hg://" url;
      }
    else if has "svn://" url then
      {
        kind = "svn";
        url = lib.removePrefix "svn://" url;
      }
    else if has "cvs://" url then
      {
        # LuaRocks takes the CVS root from the URL and the module from
        # source.module, or else from the last part of the URL.
        kind = "cvs";
        url = "${lib.removePrefix "cvs://" url} ${s.module or (baseNameOf url)}";
      }
    else if builtins.match "(https?|ftp)://.*" url != null then
      {
        kind = "file";
        inherit url basename;
        # The directory LuaRocks unpacks the archive into: source.dir, or
        # the archive name without its extensions, as LuaRocks deduces it.
        dir =
          s.dir or (builtins.head (
            builtins.match "(.*)\\.(tar\\.gz|tgz|tar\\.bz2|tbz2|tar\\.xz|txz|tar|zip|gz|bz2)" basename
            ++ [ basename ]
          ));
        # The locked download of an archive pinned by md5, which the source
        # rock holds: the lock run downloads it when it exists.
        archive = if s ? md5 then lib.findFirst (d: d.url == url) null lock.otherFiles else null;
        md5 = s.md5 or null;
      }
    else
      null;

  # The shell that stands the project source in for the rockspec's own
  # source, through LUAROCKS_PURIFIER_SELF.
  selfSetup =
    info:
    let
      r = selfRequest info;
      ref = info.source.ref or null;
      entry =
        path:
        builtins.toJSON {
          inherit (r) kind url;
          inherit ref path;
        };
    in
    if r == null then
      ""
    else if r.kind != "file" then
      ''
        export LUAROCKS_PURIFIER_SELF=${lib.escapeShellArg "[${entry "SELF"}]"}
        export LUAROCKS_PURIFIER_SELF=''${LUAROCKS_PURIFIER_SELF/SELF/$PWD}
      ''
    else if r.archive != null then
      ''
        export LUAROCKS_PURIFIER_SELF=${
          lib.escapeShellArg (
            builtins.toJSON [
              {
                kind = "file";
                inherit (r) url;
                path = "${cache.fetched.${r.archive.path}}";
              }
            ]
          )
        }
      ''
    else if r.md5 != null then
      throw "luarocks-purifier: ${info.file} pins its source archive ${r.url} by md5, and the lock run could not download it. Publish the archive (by tagging the release), then run `luarocks-purifier lock` so that the lockfile holds it."
    else
      ''
        mkdir -p "$TMPDIR/self-archive/${r.dir}"
        cp -r . "$TMPDIR/self-archive/${r.dir}/"
        archive="$TMPDIR/${r.basename}"
        case ${lib.escapeShellArg r.basename} in
          *.zip) (cd "$TMPDIR/self-archive" && zip -qr -X "$archive" ${lib.escapeShellArg r.dir}) ;;
          *.tar.bz2|*.tbz2) tar -cjf "$archive" -C "$TMPDIR/self-archive" ${lib.escapeShellArg r.dir} ;;
          *.tar.xz|*.txz) tar -cJf "$archive" -C "$TMPDIR/self-archive" ${lib.escapeShellArg r.dir} ;;
          *) tar -czf "$archive" -C "$TMPDIR/self-archive" ${lib.escapeShellArg r.dir} ;;
        esac
        LUAROCKS_PURIFIER_SELF=$(printf '[{"kind": "file", "url": %s, "path": "%s"}]' ${lib.escapeShellArg (builtins.toJSON r.url)} "$archive")
        export LUAROCKS_PURIFIER_SELF
      '';

  # The attribute name of a module file: "foo/bar.lua" and "foo/bar/init.lua"
  # are "foo.bar", and the C module "foo/bar.so" is "foo.bar".
  moduleName =
    file:
    let
      noExt = builtins.head (builtins.match "(.*)\\.[^./]+" file ++ [ file ]);
      noInit = lib.removeSuffix "/init" noExt;
    in
    builtins.replaceStrings [ "/" ] [ "." ] noInit;

  rockFor =
    info:
    stdenv.mkDerivation {
      pname = "${info.package}-src-rock";
      inherit (info) version;
      src = source;
      nativeBuildInputs = nativeTools;
      dontUseCmakeConfigure = true;
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        ${writeConfig}
        writeConfig "$TMPDIR/config.lua" '{ name = "none", root = "'"$TMPDIR"'/tree" }'
        export LUAROCKS_CONFIG=$TMPDIR/config.lua
        ${selfSetup info}
        luarocks pack ${lib.escapeShellArg info.file}
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        install -Dm644 ${lib.escapeShellArg "${info.package}-${info.version}.src.rock"} -t $out
        runHook postInstall
      '';
    };

  packageFor =
    info:
    let
      package = stdenv.mkDerivation (finalAttrs: {
        pname = info.package;
        inherit (info) version;
        src = source;
        nativeBuildInputs = nativeTools;
        buildInputs = externals;
        dontUseCmakeConfigure = true;
        dontConfigure = true;
        doCheck = false;
        buildPhase = ''
          runHook preBuild
          ${writeConfig}
          writeConfig "$TMPDIR/config.lua" '{ name = "out", root = "'"$out"'" }'
          export LUAROCKS_CONFIG=$TMPDIR/config.lua
          ${lib.concatMapStrings (file: ''
            luarocks make ${lib.escapeShellArg file} || {
              echo "luarocks-purifier: luarocks make ${file} failed offline. If it could not find a rock or a file, the lockfile lacks it: run \`luarocks-purifier lock\` in the project root." >&2
              exit 1
            }
          '') (projectDependencies info ++ [ info.file ])}
          runHook postBuild
        '';
        checkPhase = ''
          runHook preCheck
          # The test dependencies go to a tree of their own, and the rock
          # comes from the output tree.
          writeConfig "$TMPDIR/test-config.lua" '{ name = "out", root = "'"$out"'" }, { name = "test", root = "'"$TMPDIR"'/test-tree" }'
          export LUAROCKS_CONFIG=$TMPDIR/test-config.lua
          # A command-type test runs Lua on its script with LUA_PATH and
          # LUA_CPATH from the environment, which `luarocks path` sets for
          # both trees.
          eval "$(luarocks path)"
          luarocks test --tree "$TMPDIR/test-tree" ${lib.escapeShellArg info.file}
          runHook postCheck
        '';
        dontInstall = true;
        passthru = {
          bin = lib.genAttrs info.outputs.bin (name: "${finalAttrs.finalPackage}/bin/${name}");
          modules =
            builtins.listToAttrs (
              map (f: {
                name = moduleName f;
                value = "${finalAttrs.finalPackage}/share/lua/${abi}/${f}";
              }) info.outputs.lua
            )
            // builtins.listToAttrs (
              map (f: {
                name = moduleName f;
                value = "${finalAttrs.finalPackage}/lib/lua/${abi}/${f}";
              }) info.outputs.lib
            );
          inherit lua luarocks;
        };
        meta = lib.optionalAttrs (info.outputs.bin != [ ]) {
          mainProgram = builtins.head info.outputs.bin;
        };
      });
    in
    package;

  packages = builtins.listToAttrs (
    map (info: {
      name = info.package;
      value = packageFor info;
    }) lock.rockspecs
  );

  # The rock of a rockspec built again, with its test suite run after the
  # build.
  testFor =
    info:
    packages.${info.package}.overrideAttrs {
      pname = "${info.package}-tests";
      doCheck = true;
    };
in
{
  inherit packages;
  tests = linkFarm "tests" (
    map (info: {
      name = info.package;
      path = testFor info;
    }) (builtins.filter (info: info.tests) lock.rockspecs)
  );
  release = symlinkJoin {
    name = "release";
    paths = map rockFor lock.rockspecs;
  };
  fetches = lock.inMemory.entries;
}
