#!/usr/bin/env python3
"""Build a private four-file FP read-ACK candidate after leaf equivalence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from prepare_fp_read_ack_split import PARENTS, transform

KNOWN_PARENTS = {
    '8c8898416ab8af4e6e53f9c4d94e3d9c2bbd1020edce3abdb300272dfc8104d6': 'v-carry',
    'b191540ebf0e3038f7dfef1363dde38e2e73c6ca3e474bac624d6db98dafc59b': 'next-query',
}


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for flag in ('parent', 'leaf', 'out'):
        ap.add_argument('--'+flag, type=Path, required=True)
    args = ap.parse_args()
    parent, leaf = args.parent.resolve(strict=True), args.leaf.resolve(strict=True)
    root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.is_relative_to(parent)
    assert Path(os.environ['TMPDIR']).resolve() == root
    assert shutil.disk_usage(scratch).free > 4*1024**3
    old = json.loads((parent/'build-started.json').read_text())
    closed = json.loads((parent/'build-closed.json').read_text())
    assert closed['passed'] and closed['pins_unchanged'] and closed['native_exit'] == 0
    assert sha(parent/'obj/tb_ventium') == closed['binary_sha256']
    assert closed['binary_sha256'] in KNOWN_PARENTS
    checked = json.loads((leaf/'closed.json').read_text())
    assert checked['passed'] and checked['pins_unchanged'] and len(checked['runs']) == 13
    pins = dict(old['pins'])
    pins.update(json.loads((leaf/'pins.json').read_text()))
    assert all(sha(p) == h for p, h in pins.items())
    changed = {name: transform(name, (parent/'candidate'/name).read_text()) for name in PARENTS}
    assert all(text == (leaf/'candidate'/name).read_text() for name,text in changed.items())
    root.mkdir()
    shutil.copytree(parent/'candidate', root/'candidate')
    for name,text in changed.items():
        (root/'candidate'/name).write_text(text)
    changes = [str(p.relative_to(root/'candidate')) for p in (root/'candidate').rglob('*')
        if p.is_file() and sha(p) != sha(parent/'candidate'/p.relative_to(root/'candidate'))]
    assert sorted(changes) == sorted(PARENTS)
    oldhost = Path(old['host'])
    host = root/('tb_fp_read_ack_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(oldhost, host)
    command = [s.replace(str(parent/'candidate'), str(root/'candidate')).replace(str(parent/'obj'), str(root/'obj'))
        .replace(str(oldhost), str(host)) for s in old['command']]
    for p in (Path(__file__), Path(__file__).with_name('prepare_fp_read_ack_split.py'),
              parent/'build-started.json', parent/'build-closed.json', parent/'obj/tb_ventium',
              leaf/'closed.json', leaf/'pins.json', host):
        pins[str(p)] = sha(p)
    for p in (root/'candidate').rglob('*'):
        if p.is_file(): pins[str(p)] = sha(p)

    def save(name, value):
        with (root/name).open('x') as f:
            json.dump(value, f, indent=2)

    save('build-started.json', dict(command=command, pins=pins, host=str(host), changes=changes,
        parent_model=closed['binary_sha256'], parent_label=KNOWN_PARENTS[closed['binary_sha256']],
        invocation=os.environ.get('INVOCATION_ID'), gameplay_ipc=None))
    env = dict(os.environ, CCACHE_DISABLE='1', PYTHONDONTWRITEBYTECODE='1',
        VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32', VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32',
        VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator')
    result = dict(passed=False, errors=[], gameplay_ipc=None, standard_suite=False)
    begin = time.monotonic()
    try:
        with (root/'build.log').open('x') as f:
            p = subprocess.run(command, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=600)
        result['native_exit'] = p.returncode
        assert p.returncode == 0
        obj = root/'obj'
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n', ' ').split()
            if Path(s).name == 'Vventium_top___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vventium_top___024root.h').resolve()
        result.update(passed=True, binary_sha256=sha(obj/'tb_ventium'), private_header=str(header))
    except Exception as error:
        result['errors'].append(repr(error))
    finally:
        result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()), seconds=time.monotonic()-begin)
        result['passed'] &= result['pins_unchanged']
        save('build-closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
