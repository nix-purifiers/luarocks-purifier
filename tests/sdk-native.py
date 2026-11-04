#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exact Lua SDK points: native capture, C ABI, offline/pure builds and source rocks."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading

flake = Path(__file__).resolve().parents[1]
cli = Path(sys.argv[1]).resolve() / 'bin/luarocks-purifier'
point = sys.argv[2]

def run(args, cwd, env, capture=False):
    return subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True,
                          text=True, stdout=subprocess.PIPE if capture else None).stdout

expression = '''let f=builtins.getFlake ("path:"+builtins.getEnv "LUA_SDK_FLAKE");
 p=import f.inputs.nixpkgs {system=builtins.currentSystem;};
 sdk=(import (f.outPath+"/nix/lib/lua.nix") {pkgs=p;}).${builtins.getEnv "LUA_SDK_POINT"};
 in { lua=p.lib.getExe sdk; manager=toString sdk.pkgs.luarocks; version=sdk.version; buildPath=p.lib.makeBinPath [p.stdenv.cc p.gnumake p.unzip p.zip p.gnutar p.gzip p.curl]; }'''
env = dict(os.environ, LUA_SDK_FLAKE=str(flake), LUA_SDK_POINT=point, LC_ALL='C')
metadata = json.loads(run(['nix','eval','--impure','--json','--expr',expression], flake, env, True))
env['PATH'] = metadata['buildPath'] + os.pathsep + env['PATH']
lua = metadata['lua']
manager = Path(metadata['manager']) / 'bin/luarocks'
with tempfile.TemporaryDirectory(prefix='lua-sdk-native-') as temporary:
    base = Path(temporary).resolve()
    root = base/'project'
    root.mkdir()
    env.update(HOME=str(base/'home'), XDG_CONFIG_HOME=str(base/'home/.config'),
               LUA_INIT='@'+str(flake/'nix/lib/tmpname.lua'))
    Path(env['HOME']).mkdir()
    server_root = base/'server'
    server_root.mkdir()
    dependency = base/'answer-1.0'
    dependency.mkdir()
    (dependency/'answer.lua').write_text('return 41\n')
    with tarfile.open(server_root/'answer-1.0.tar.gz', 'w:gz') as archive:
        archive.add(dependency, arcname=dependency.name)
    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass
    server = ThreadingHTTPServer(('127.0.0.1',0), partial(Handler,directory=str(server_root)))
    threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        port = server.server_port
        rocks = root/'rocks'
        rocks.mkdir()
        (rocks/'answer-1.0-1.rockspec').write_text('''package="answer"
version="1.0-1"
source={url="http://127.0.0.1:PORT/answer-1.0.tar.gz"}
dependencies={"lua >= 5.1"}
build={type="builtin",modules={answer="answer.lua"}}
'''.replace('PORT',str(port)))
        run([manager.with_name('luarocks-admin'),'make_manifest',rocks],root,env)
        (root/'native.c').write_text('''#include <lua.h>
#include <lauxlib.h>
static int answer(lua_State *L) { lua_pushinteger(L, 1); return 1; }
int luaopen_native(lua_State *L) {
  lua_newtable(L); lua_pushcfunction(L, answer); lua_setfield(L, -2, "answer"); return 1;
}
''')
        (root/'application.lua').write_text('return require("answer") + require("native").answer()\n')
        (root/'test.lua').write_text('assert(require("application") == 42)\n')
        spec=root/'application-1.0-1.rockspec'
        spec.write_text('''rockspec_format="3.0"
package="application"
version="1.0-1"
source={url="https://example.invalid/application-1.0.tar.gz"}
dependencies={"lua >= 5.1", "answer == 1.0"}
build={type="builtin",modules={application="application.lua",native="native.c"}}
test={type="command",script="test.lua"}
''')
        original={p.name:p.read_bytes() for p in root.iterdir() if p.is_file()}
        run([cli,'lock','--lua',point,'--only-server','./rocks'],root,env)
        lock=root/'luarocks-purifier.lock.json'
        saved=lock.read_bytes()
        run([cli,'lock'],root,env)
        assert lock.read_bytes()==saved, 'capture is not repeatable'
        assert json.loads(saved)['lua']==point
        run([cli,'prefetch'],root,env)
        offline=dict(env,HTTP_PROXY='http://127.0.0.1:9',HTTPS_PROXY='http://127.0.0.1:9',ALL_PROXY='http://127.0.0.1:9')
        server.shutdown()
        run([cli,'luarocks','make'],root,offline)
        run([cli,'luarocks','test'],root,offline)
        abi='5.1' if point=='luajit' else point
        installed=dict(offline,LUA_PATH=str(root/'lua_modules/share/lua'/abi/'?.lua')+';;',
                       LUA_CPATH=str(root/'lua_modules/lib/lua'/abi/'?.so')+';;')
        run([lua,'-e','assert(require("application")==42)'],root,installed)
        assert lock.read_bytes()==saved
        for name,data in original.items():
            assert (root/name).read_bytes()==data, name
        build_env=dict(env,LUA_SDK_SOURCE=str(root))
        build_expression='''let f=builtins.getFlake ("path:"+builtins.getEnv "LUA_SDK_FLAKE");
          p=import f.inputs.nixpkgs {system=builtins.currentSystem;overlays=[f.overlays.default];};
          project=p.luarocks-purifier.buildLuarocksProject {src=/. + builtins.getEnv "LUA_SDK_SOURCE";};
          in [project.packages.application project.tests project.release]'''
        built=json.loads(run(['nix','build','--impure','--no-link','--json','--expr',build_expression],root,build_env,True))
        paths=[Path(output) for item in built for output in item['outputs'].values()]
        package=next(p for p in paths if (p/'share/lua'/abi/'application.lua').exists())
        pure_env=dict(offline,LUA_PATH=str(package/'share/lua'/abi/'?.lua')+';;',LUA_CPATH=str(package/'lib/lua'/abi/'?.so')+';;')
        run([lua,'-e','assert(require("application")==42)'],root,pure_env)
        release=next(p for p in paths if (p/'application-1.0-1.src.rock').exists())
        # A fresh ordinary LuaRocks installs the prepared source release and
        # resolves its dependency through the local native rockspec repository.
        consumer=base/'consumer'
        consumer.mkdir()
        # Restart the original fixture endpoint for the ordinary consumer;
        # purifier build/test above already succeeded while it was unavailable.
        threading.Thread(target=server.serve_forever,daemon=True).start()
        run([manager,'--tree',str(consumer/'tree'),'--only-server',str(rocks),'install',release/'application-1.0-1.src.rock'],consumer,env)
        consumer_env=dict(env,LUA_PATH=str(consumer/'tree/share/lua'/abi/'?.lua')+';;',LUA_CPATH=str(consumer/'tree/lib/lua'/abi/'?.so')+';;')
        run([lua,'-e','assert(require("application")==42)'],consumer,consumer_env)
        print('PASS native Lua '+metadata['version']+' / '+point+': capture, dependency, C ABI, offline native/pure tests, source rock and ordinary install')
    finally:
        server.shutdown()
        server.server_close()
