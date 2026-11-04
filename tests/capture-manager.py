# SPDX-License-Identifier: MIT
"""Actual native manager metadata discovery, repeated capture and update."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

cli = Path(sys.argv[1]) / 'bin/luarocks-purifier'
with tempfile.TemporaryDirectory(prefix='manager-capture-') as temporary:
    root = Path(temporary).resolve()
    (root/'rocks').mkdir()
    (root/'legacy.lua').write_text('return 42\n')
    spec = root/'legacy-1.0-1.rockspec'
    spec.write_text('''package="legacy"
version="1.0-1"
source={url="https://example.invalid/legacy-1.0.tar.gz"}
dependencies={"lua >= 5.1"}
build={type="builtin",modules={legacy="legacy.lua"}}
''')
    original = spec.read_bytes()
    env = dict(os.environ, HOME=str(root/'home'), LC_ALL='C')
    (root/'home').mkdir()
    def run(*args):
        subprocess.run([str(cli), *args], cwd=root, env=env, check=True)
    run('lock', '--lua', '5.1', '--only-server', './rocks')
    lock = root/'luarocks-purifier.lock.json'
    saved = lock.read_bytes()
    data = json.loads(saved)
    assert data['rockspecs'][0]['outputs'] == {'bin': [], 'lua': ['legacy.lua'], 'lib': []}
    run('lock')
    assert lock.read_bytes() == saved
    run('update')
    assert 'dependencies' in (root/'luarocks.lock').read_text()
    assert 'legacy' not in (root/'luarocks.lock').read_text(), 'project itself became a dependency'
    updated = lock.read_bytes()
    run('lock')
    assert lock.read_bytes() == updated
    assert spec.read_bytes() == original
    assert (root/'legacy.lua').read_text() == 'return 42\n'
    print('PASS native manager show/list metadata, repeated capture, update and unchanged sources')
