"""Derive strictly scoped store tests/builds from immutable restore drivers.

Only parent identity, fixture paths, expected leaf witness, and mode enumeration
change. Native exits, complete trace comparison, resource and source guards stay.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
OLD = HERE.parent/'fp_env_restore'
MODEL = '33173110a2463f6512326c56c47fb532357a2baf5596751df0a48a94ba62d0f3'
DRIVERS = {
    'leaf': ('run_leaf.py', '7b3ebbcf4867b87f7b3907367506d9bc4db462f8d5970f630c6bb4efaf2a38a4'),
    'core': ('build_core.py', '96b6e366768a8dcb00e49bc79661b7923094bb7d13d0f84a26edc411f7d6051c'),
    'modes': ('run_modes.py', '6ddf289d73b7c8fc9d3f4d1d9ca9c8740a3b056c5b2054f60df1cc3a52e55362'),
    'replay': ('run_regression.py', 'accb57e5ecf8637187d0f9087933368d4cf2e1d94ae76cde53db743fe33afd91'),
}


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def replace(text, before, after, count=1):
    assert text.count(before) == count, before
    return text.replace(before, after)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('phase', choices=DRIVERS)
    for name in ('out', 'parent', 'leaf', 'core', 'candidate'):
        ap.add_argument('--'+name, type=Path, required=(name=='out'))
    a = ap.parse_args()
    root = a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    name, digest = DRIVERS[a.phase]
    source = OLD/name
    assert sha(source) == digest
    text = replace(source.read_text(), 'HERE=Path(__file__).resolve().parent',
                   'HERE=Path('+repr(str(HERE))+')')
    if a.phase in ('leaf', 'core'):
        text = replace(text, '2fc497047dc64848f28a920522a6fa4ec1e8ef0c686179394576d6237402acb2', MODEL)
        text = replace(text, 'ENV-POINTER mode=0 full=0 sample=0',
                       'ENV-STORE32 mode=2 full=0 sample=0')
        text = replace(text, 'FP-ENV-RESTORE-OK cases=1024',
                       'FP-ENV-STORE-OK cases=1024 stores=4096')
    if a.phase == 'modes':
        text = replace(text,
            'dict(MODE=m,ENV16=e,FULL=f,SHIFT=s,PENDING=0,PREFIX=0,LOCKED=0,CONTROL=1)\n'
            '              for m,e,f,s in itertools.product((0,1,2),(0,1),(0,1),(0,1,63,4090))',
            'dict(MODE=m,IN16=i,OUT16=o,FULL=f,SAVE=v,SHIFT=s,PENDING=0,PREFIX=0,LOCKED=0,CONTROL=1)\n'
            '              for m,i,o,f,v,s in itertools.product((0,1,2),(0,1),(0,1),(0,1),(0,1),(0,1,63,4090))')
        text = replace(text, 'cases=48', 'cases=192')
        text = replace(text, "driver=root.with_suffix('.driver.py')",
                       "driver=root.with_suffix('.native-driver.py')")
        text = replace(text, "root.with_suffix('.driver.json')",
                       "root.with_suffix('.native-driver.json')")
    if a.phase == 'replay':
        text = replace(text, "driver=out.with_suffix('.driver.py')",
                       "driver=out.with_suffix('.native-driver.py')")
        text = replace(text, "out.with_suffix('.driver.json')",
                       "out.with_suffix('.native-driver.json')")
    driver = root.with_suffix('.driver.py')
    with driver.open('x') as f:
        f.write('import sys\nsys.path.insert(0, '+repr(str(HERE))+')\n'+text)
    pins = {str(p):sha(p) for p in (Path(__file__), source, driver,
            HERE/'prepare.py', HERE/'test_prepare.py', HERE/'tb_restore.sv',
            HERE/'restore.S', HERE/'restore.ld')}
    command = [sys.executable, '-B', str(driver), '--out', str(root)]
    keys = {'leaf': ('parent',), 'core': ('parent','leaf'), 'modes': ('core',),
            'replay': ('parent','candidate')}[a.phase]
    for key in keys:
        assert getattr(a, key)
        command += ['--'+key, str(getattr(a, key).resolve(strict=True))]
    with root.with_suffix('.driver.json').open('x') as f:
        json.dump(dict(pins=pins, command=command, native_acceptance_unchanged=True,
                       phase=a.phase), f, indent=2)
    result = subprocess.run(command, timeout=700,
                            pass_fds=(9,) if a.phase in ('leaf','core') else ())
    assert all(sha(p)==h for p,h in pins.items())
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
