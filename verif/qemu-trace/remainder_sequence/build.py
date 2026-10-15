"""Fresh bounded private QEMU build; refuse concurrent Vivado or source drift."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import traceback

import prepare

REPO = Path(__file__).resolve().parents[3]
PARENT = Path('/home/yukidama/external/tmp/ventium-qemu-frndint.wRXifJwr/build-r1')
PARENT_BINARY_SHA = 'da49b8105f90b4257494a7b7f1e57e5428fa66dc667278b824d381d9d0e9f84d'


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, value):
    with p.open('x') as f:
        json.dump(value, f, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', required=True, type=Path)
    root = ap.parse_args().out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3 + 350*1024**2
    assert os.sched_getaffinity(0) == set(range(8, 16)) and os.environ['INVOCATION_ID']
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
        'MemoryMax=10G','MemorySwapMax=2G'],check=True)
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, pass_fds=(9,))
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    parent = json.loads((PARENT/'closed.json').read_text())
    inventory = json.loads((PARENT/'source.json').read_text())['after']
    assert parent['passed'] and parent['pins_unchanged']
    assert sha(parent['binary']) == parent['sha256'] == PARENT_BINARY_SHA
    pins = {str(PARENT/'source'/n): h for n, h in inventory.items()}
    for p in (Path(__file__), Path(prepare.__file__), PARENT/'closed.json',
              PARENT/'source.json', Path(parent['binary']), REPO/'tools/build_scope.sh',
              Path('/home/yukidama/miniconda3/bin/ninja')):
        pins[str(p.resolve())] = sha(p)
    assert all(sha(p) == h for p, h in pins.items())
    derived = prepare.transform((PARENT/'source'/prepare.HELPER).read_text())
    root.mkdir(); source = root/'source'; build = root/'build'
    source.mkdir(); build.mkdir()
    save(root/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        parent=str(PARENT), affinity=sorted(os.sched_getaffinity(0)), canonical_changed=False,
        free_bytes=shutil.disk_usage(scratch).free, allocated_budget_bytes=350*1024**2))
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', PATH='/home/yukidama/miniconda3/bin:/usr/bin:/bin')
    env.pop('VTM_QEMU_GDB_PREEXIT', None)
    rows = []; start = time.monotonic()
    result = dict(passed=False, errors=[], canonical_gate_passed=False,
                  standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)

    def run(label, command, cwd):
        begin = time.monotonic()
        with (root/(label+'.log')).open('x') as f:
            done = subprocess.run(command, cwd=cwd, env=env, stdout=f,
                stderr=subprocess.STDOUT, timeout=420, pass_fds=(9,))
        row = dict(label=label, command=list(map(str, command)), cwd=str(cwd),
                   native_exit=done.returncode, seconds=time.monotonic()-begin)
        rows.append(row); save(root/(label+'.json'), row)
        assert done.returncode == 0, row

    try:
        run('copy', ['rsync', '-a', str(PARENT/'source')+'/', str(source)+'/'], root)
        assert all(sha(source/n) == h for n, h in inventory.items())
        (source/prepare.HELPER).write_text(derived)
        after = {n: sha(source/n) for n in inventory}
        delta = [n for n in inventory if inventory[n] != after[n]]
        assert delta == [prepare.HELPER]
        save(root/'source.json', dict(before=inventory, after=after, changed=delta))
        run('configure', [source/'configure', '--target-list=i386-linux-user',
            '--enable-plugins', '--python=/usr/bin/python3', '--disable-system',
            '--disable-tools', '--disable-docs', '--disable-werror', '--disable-download'], build)
        assert shutil.disk_usage(scratch).free > 4*1024**3 + 100*1024**2
        run('compile', ['/home/yukidama/miniconda3/bin/ninja', '-j32', 'qemu-i386'], build)
        assert all(sha(source/n) == h for n, h in after.items())
        version = subprocess.check_output([build/'qemu-i386', '--version'], text=True)
        assert '8.2.2' in version
        result.update(passed=True, binary=str(build/'qemu-i386'), sha256=sha(build/'qemu-i386'),
                      source_files=len(after), changed=delta, version=version)
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(rows=rows, seconds=time.monotonic()-start,
        pins_unchanged=all(sha(p) == h for p, h in pins.items()), free_bytes=shutil.disk_usage(scratch).free)
    result['passed'] &= result['pins_unchanged'] and result['free_bytes'] > 4*1024**3
    save(root/'closed.json', result)
    print(json.dumps(result, indent=2), flush=True)
    return int(not result['passed'])


if __name__ == '__main__':
    raise SystemExit(main())
