#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Both original SDK recipes survive copying without realizing either SDK."""
import json
from pathlib import Path
import subprocess
import tempfile


def output(*args):
    return subprocess.check_output(args, text=True).strip()


carrier = output('nix', 'build', '--impure', '--no-link', '--print-out-paths', '--expr',
                 '(import ./tests/sdk-runtime.nix {}).carrier')
data = json.loads(output('nix', 'eval', '--impure', '--json', '--expr',
    'let d=import ./tests/sdk-runtime.nix {}; in {inherit(d) descriptors outputs;}'))
with tempfile.TemporaryDirectory(prefix='lua-sdk-copy-') as temporary:
    root = Path(temporary).resolve()
    cache = 'file://' + str(root/'cache')
    cold = 'local?root=' + str(root/'cold')
    subprocess.run(['nix','copy','--to',cache,carrier],check=True)
    subprocess.run(['nix','copy','--from',cache,'--to',cold,'--no-check-sigs',carrier],check=True)
    physical = root/'cold/nix/store'
    for descriptor in data['descriptors']:
        assert (physical/Path(descriptor).name).is_file(), 'SDK recipe lost during normal copy'
    for path in data['outputs']:
        assert not (physical/Path(path).name).exists(), 'SDK was unexpectedly realized'
    expression = 'let sdk = '+Path(carrier).read_text()+'; in {runtime=toString sdk.target.lua; manager=toString sdk.target.luarocks; selected=sdk.target.lua.outputName;}'
    restored = json.loads(output('nix','eval','--store',cold,'--offline','--impure',
                                 '--option','allow-import-from-derivation','false','--json','--expr',expression))
    assert restored['runtime'] == data['outputs'][0]
    assert restored['manager'] == data['outputs'][1]
    assert restored['selected'] == 'secondary'
print('PASS both selected SDK recipes survive cold-store copy without realization or IFD')
