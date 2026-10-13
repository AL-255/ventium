"""Full private QEMU build of C1/remainder/environment plus pre-exit observer."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback

import prepare

REPO = Path(__file__).resolve().parents[3]
PARENT = Path('/home/yukidama/external/tmp/ventium-qemu-preexit-r2.81Yu1ixT')


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, data):
    with p.open('x') as f:
        json.dump(data, f, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    root = a.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert shutil.disk_usage(scratch).free>4*1024**3+300*1024**2
    assert os.sched_getaffinity(0)==set(range(8,16)) and os.environ['INVOCATION_ID']
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'], check=True, pass_fds=(9,))
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode==1
    source_parent = (PARENT/'observer-source').resolve(strict=True)
    inventory = json.loads((PARENT/'observer-source.json').read_text())['after']
    pins = {str(source_parent/n):h for n,h in inventory.items()}
    for p in (Path(__file__), Path(prepare.__file__), Path(prepare.rounding.__file__),
              Path(prepare.remainder.__file__), Path(prepare.environment.__file__),
              PARENT/'observer-source.json', PARENT/'observer-build/qemu-i386',
              REPO/'tools/build_scope.sh', Path('/home/yukidama/miniconda3/bin/ninja')):
        pins[str(p.resolve())] = sha(p)
    assert sha(PARENT/'observer-build/qemu-i386')=='52a9ca27d2d1bb40a360a7c2e881b8fe63b0795f285ae823b96e33e75ef0ff31'
    assert all(sha(p)==h for p,h in pins.items())
    changed = prepare.transform({n:(source_parent/n).read_text() for n in
        set(prepare.rounding.PARENTS)|set(prepare.remainder.PARENTS)|{prepare.HELPER}})
    root.mkdir()
    source, build = root/'source', root/'build'
    source.mkdir(); build.mkdir()
    save(root/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        affinity=sorted(os.sched_getaffinity(0)), parent=str(source_parent), canonical_changed=False))
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1',
               PATH='/home/yukidama/miniconda3/bin:/usr/bin:/bin')
    env.pop('VTM_QEMU_GDB_PREEXIT', None)
    rows = []
    def run(label, command, cwd):
        start = time.monotonic()
        with (root/(label+'.log')).open('x') as log:
            code = subprocess.run(command, cwd=cwd, env=env, stdout=log,
                stderr=subprocess.STDOUT, timeout=420, pass_fds=(9,)).returncode
        row = dict(label=label, command=list(map(str,command)), cwd=str(cwd),
                   native_exit=code, seconds=time.monotonic()-start)
        rows.append(row); save(root/(label+'.json'), row)
        assert code==0, (label, code)
    begin = time.monotonic()
    result = dict(passed=False, errors=[], canonical_gate_passed=False,
                  standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    try:
        run('copy', ['rsync','-a',str(source_parent)+'/',str(source)+'/'], root)
        assert all(sha(source/n)==h for n,h in inventory.items())
        for n, value in changed.items():
            (source/n).write_text(value)
        after = {n:sha(source/n) for n in inventory}
        delta = sorted(n for n in inventory if inventory[n]!=after[n])
        assert delta==sorted(changed)
        save(root/'source.json', dict(before=inventory, after=after, changed=delta))
        run('configure', [source/'configure','--target-list=i386-linux-user',
            '--enable-plugins','--python=/usr/bin/python3','--disable-system',
            '--disable-tools','--disable-docs','--disable-werror','--disable-download'], build)
        assert shutil.disk_usage(scratch).free>4*1024**3+80*1024**2
        run('compile', ['/home/yukidama/miniconda3/bin/ninja','-j32','qemu-i386'], build)
        assert all(sha(source/n)==h for n,h in after.items())
        version = subprocess.check_output([build/'qemu-i386','--version'], text=True)
        assert '8.2.2' in version
        result.update(passed=True, binary=str(build/'qemu-i386'), sha256=sha(build/'qemu-i386'),
                      source_unchanged=True, source_files=len(after), changed=delta, version=version)
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(rows=rows, seconds=time.monotonic()-begin,
                  pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save(root/'closed.json', result)
    print(json.dumps(result, indent=2), flush=True)
    return int(not result['passed'])


if __name__=='__main__':
    raise SystemExit(main())
