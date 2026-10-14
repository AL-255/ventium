"""Run unchanged original boundary BIOSes against matched private QEMUs.

This qualifies only the upstream SMC correction, not the whole boundary gate:
the finite-CS-limit QEMU discrepancy must remain visible. No RTL is run or
qualified here, and debug single stepping is deliberately absent.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time
import traceback

import prepare

REPO = Path(__file__).resolve().parents[3]
SCRATCH = Path('/home/yukidama/external/tmp')
CANONICAL_SHA = 'b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def expected(kind, offset, variant):
    # KIND2 tests a separate, still-unrepaired CS-limit exception omission.
    if kind == 2 or (kind == 3 and offset >= 4094 and variant == 'control'):
        return 135
    return 133


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--original', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root, source, build = args.out.resolve(), args.original.resolve(strict=True), args.build.resolve(strict=True)
    scratch = SCRATCH.resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and root != scratch and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert os.environ['INVOCATION_ID'] and os.sched_getaffinity(0) == set(range(12,16))
    assert shutil.disk_usage(scratch).free > 4*1024**3
    before = json.loads((source/'started.json').read_text())
    old_closed = json.loads((source/'closed.json').read_text())
    built = json.loads((build/'closed.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and len(built['rows']) == 2
    assert not old_closed['passed'] and len(old_closed['errors']) == 12 and old_closed['pins_unchanged']
    cases = [tuple(case) for case in before['cases']]
    assert len(cases) == len(set(cases)) == 30
    assert sum(kind == 3 for kind,reloc,offset in cases) == 8
    assert sum(kind == 2 for kind,reloc,offset in cases) == 8
    assert cases == [(kind,reloc,offset) for kind in range(4) for reloc in (0,1)
                     for offset in (4080,4093,4094,4095) if kind != 1 or offset > 4092]
    pins = dict(before['pins'])
    for name,digest in built['pins'].items():
        assert name not in pins or pins[name] == digest
        pins[name] = digest
    binaries = {row['variant']:Path(row['binary']) for row in built['rows']}
    assert set(binaries) == {'control','candidate'}
    bios = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/pc-bios'
    assert (bios/'vgabios-stdvga.bin').is_file() and (bios/'kvmvapic.bin').is_file()
    for path in bios.rglob('*'):
        if path.is_file():
            pins[str(path.resolve())] = sha(path)
    original = (build/'control/tb-maint.c').read_text()
    assert (build/'candidate/tb-maint.c').read_text() == prepare.transform(original)
    for row in built['rows']:
        assert sha(row['binary']) == row['sha256']
        pins.update(row['artifacts'])
    for path in (source/'started.json', source/'closed.json', build/'closed.json',
                 Path(__file__), Path(prepare.__file__)):
        pins[str(path)] = sha(path)
    for kind,reloc,offset in cases:
        leaf = source/f'k{kind}-r{reloc}-o{offset}'
        for name in ('test.bin', 'test.elf', 'free-qemu.argv.json', 'free-qemu.exit.json'):
            pins[str(leaf/name)] = sha(leaf/name)
        assert json.loads((leaf/'free-qemu.exit.json').read_text())['native_exit'] == expected(kind,offset,'control')
    assert all(sha(path) == digest for path,digest in pins.items())
    root.mkdir()
    save(root/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'], cases=cases,
         canonical_changed=False, rtl_changed=False, guest_images_unchanged=True))
    env = {key:value for key,value in os.environ.items()
           if not key.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(root), PYTHONDONTWRITEBYTECODE='1')

    def one(index_case):
        index,(kind,reloc,offset) = index_case
        case = f'k{kind}-r{reloc}-o{offset}'
        leaf = root/case
        leaf.mkdir()
        old_command = json.loads((source/case/'free-qemu.argv.json').read_text())
        assert old_command[:4] == ['timeout','--signal=TERM','--kill-after=3s','45s']
        command = old_command[4:]
        assert sha(command[0]) == CANONICAL_SHA
        assert Path(command[command.index('-bios')+1]).resolve() == source/case/'test.bin'
        assert not set(command) & {'-S','-s','-gdb','-singlestep','-accel'}
        rows = []
        for variant,binary in binaries.items():
            cpu = 12+index%4
            # A relocated QEMU executable no longer finds its source-tree ROM
            # directory automatically. Bind the same original option ROMs.
            argv = ['taskset','-c',str(cpu),str(binary),'-L',str(bios),*command[1:]]
            start = time.monotonic()
            observed = False
            code = None
            save(leaf/(variant+'.argv.json'), argv)
            with (leaf/(variant+'.stdout')).open('x') as out, (leaf/(variant+'.stderr')).open('x') as err:
                process = subprocess.Popen(argv, stdout=out, stderr=err, env=env, start_new_session=True)
                try:
                    while process.poll() is None:
                        assert time.monotonic()-start < 20
                        assert shutil.disk_usage(scratch).free > 4*1024**3
                        try:
                            if Path('/proc',str(process.pid),'exe').resolve(strict=True) == binary:
                                assert os.sched_getaffinity(process.pid) == {cpu}
                                observed = True
                        except (FileNotFoundError, ProcessLookupError):
                            pass
                        time.sleep(.001)
                    code = process.wait()
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid,signal.SIGTERM)
                        try:
                            process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            os.killpg(process.pid,signal.SIGKILL)
                            process.wait()
                row = dict(variant=variant, native_exit=code, expected_exit=expected(kind,offset,variant),
                           child_reaped=not Path('/proc',str(process.pid)).exists(),
                           actual_affinity_observed=observed, seconds=time.monotonic()-start)
                save(leaf/(variant+'.closed.json'), row)
                assert observed and row['child_reaped'] and code == row['expected_exit'], row
                rows.append(row)
        return dict(case=case, kind=kind, rows=rows, image_sha256=sha(source/case/'test.bin'))

    begin = time.monotonic()
    rows,errors = [],[]
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [(case,pool.submit(one,(index,case))) for index,case in enumerate(cases)]
        for case,future in futures:
            try:
                rows.append(future.result())
            except Exception as error:
                errors.append(dict(case=case, error=repr(error), traceback=traceback.format_exc()))
    stable = all(sha(path) == digest for path,digest in pins.items())
    result = dict(native_backport_passed=not errors and stable and len(rows) == 30,
                  rows=rows, errors=errors, pins_unchanged=stable, seconds=time.monotonic()-begin,
                  original_boundary_gate_passed=False, canonical_gate_passed=False,
                  finite_cs_limit_discrepancy_unfixed=True, full_trace_differential_passed=False,
                  standard_suite=False, hardware_acceptance=False, gameplay_ipc=None,
                  artifacts={str(path.relative_to(root)):sha(path) for path in root.rglob('*') if path.is_file()})
    save(root/'closed.json', result)
    print(json.dumps({key:value for key,value in result.items() if key not in ('rows','artifacts')},indent=2),flush=True)
    return int(not result['native_backport_passed'])


if __name__ == '__main__':
    raise SystemExit(main())
