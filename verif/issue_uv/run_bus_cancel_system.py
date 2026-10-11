#!/usr/bin/env python3
"""Cold full-core bus-cancellation checks: faults, fragments and A20.

Assemble the original fixtures privately, correcting only the legacy A20
fixture's reset bit. Compare every architectural and cycle record; no saved
state, golden masks, terminal trimming or RTL rebuild. The pre-existing
pfetchlim gate uses precise-fault witnesses, not a QEMU differential.
SMM and reset injection require separate tests and are not claimed here.
"""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import traceback

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import compare
import tracefmt
spec = importlib.util.spec_from_file_location('fp_payload', Path(__file__).with_name('run-fp-payload-ab.py'))
grade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grade)

# (directory, basename, linker, instruction cap, x87 comparison)
CASES = (
    ('pxfrag', 'pxfrag', 'pxfrag.ld', 3000, False),
    ('pxc04', 'pxc04', 'pxc04.ld', 1400, False),
    ('pxc04e', 'pxc04e', 'pxc04e.ld', 1400, True),
    ('pxc04f', 'pxc04f', 'pxc04f.ld', 1400, True),
    ('pfault', 'pfault', 'pfault.ld', 400, False),
    ('pfetchlim', 'pfetchlim', 'pfetchlim.ld', 2000, False),
    ('prsmflush', 'prsmflush', 'prsmflush.ld', 6000, False),
    ('mabench', 'a20test', 'mabench.ld', 4000, False),
    ('mabench', 'a20cmdtest', 'mabench.ld', 10000, False),
)
WITNESSES = {
    'pxfrag': dict(ecx=0x201, edi=0x600df00d, ebx=0xfeedface, ebp=0xbeefcafe, esi=0xc001d00d),
    'pxc04': dict(ecx=4, edi=0x600df00d, ebx=0x600df00d, ebp=0xdeadbeef, esi=0xcafebabe),
    'pxc04e': dict(ecx=4, edi=0x600df00d, ebx=0xffff037f, ebp=0, esi=0xcafebabe),
    'pxc04f': dict(ecx=4, edi=0x600df00d, ebx=0x3ff00000, ebp=0, esi=0xcafebabe),
    'pfetchlim': dict(ecx=4, ebp=0x5eedb005, edi=0x5eedc101, esi=0x5eedc202),
    'prsmflush': dict(edi=0xb0020002, esi=0xc0020002, ebx=0xb0010001, ebp=0xc0010001, ecx=0xb0080008),
}
A20 = 'A=1111 B=3333 C=0000 D=3333'
A20CMD = '@1111:2222:2222:1111:1111:3333:2222:2222:3333:3333:4444:'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def witness(name, trace, log=None, architectural=True):
    # Cycle traces deliberately contain no GPR state. Check the full functional
    # stream's witnesses and compare cycle records separately, never fabricate
    # register fields in a cycle trace.
    if architectural:
        for key, value in WITNESSES.get(name, {}).items():
            assert int(trace.records[-1][key], 0) == value, (name, key, trace.records[-1][key], value)
    if log is not None and name in ('a20test', 'a20cmdtest'):
        expected = A20 if name == 'a20test' else A20CMD
        assert log.count(expected) == 1, (name, 'missing complete A20 witness')


def a20_no_reset(source):
    old = '    movb $0x02,%al                    /* bit 1 = 1 -> A20 ENABLED */'
    new = '    movb $0x03,%al                    /* A20 enabled, active-low reset deasserted */'
    assert source.count(old) == 1 and new not in source
    changed = source.replace(old, new)
    assert changed.replace(new, old) == source
    return changed


def fetch_fault_witness(log):
    faults = re.findall(r'^\[FAULT\] vec=(\d+) err=([0-9a-f]{8}) pc=([0-9a-f]{8})\b', log, re.M)
    assert sorted(faults) == [('13', '00000000', pc)
                             for pc in ('0000003b', '0000003c', '0000003f', '00000040')], faults


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control', 'candidate', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3 and os.environ.get('INVOCATION_ID')
    models = dict(control=args.control.resolve(strict=True), candidate=args.candidate.resolve(strict=True))
    pins, profiles = {}, []
    for model in models.values():
        stamp = model.parent/'Vventium_top__verFiles.dat'
        command = next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
        defs = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command
        assert {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SEG_ENFORCE', 'VEN_SYS_FASTPATH_RELOC',
                'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT'} <= defs
        assert not {'VEN_SYS_FASTPATH_ALL', 'VTM_NO_DPI', 'SYNTHESIS'} & defs
        profiles.append(defs)
        pins.update({str(path): sha(path) for path in (model, stamp)})
    assert profiles[0] == profiles[1]
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    sources = REPO/'verif/sys/tests'
    for folder, name, linker, _, _ in CASES:
        for path in (sources/folder/(name+'.S'), sources/folder/linker):
            pins[str(path)] = sha(path)
    for path in (Path(__file__), Path(__file__).with_name('run-fp-payload-ab.py'),
                 REPO/'verif/diff/compare.py', REPO/'verif/diff/tracefmt.py',
                 REPO/'verif/sys/run-native-system.py', REPO/'verif/qemu-trace/gen_trace.py', qemu,
                 REPO/'verif/sys/run-seg-gate.sh',
                 REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/hw/input/pckbd.c'):
        pins[str(path)] = sha(path)
    out.mkdir()
    # The original data=0x02 asserts CPU reset in an actual 8042. Retain the
    # failed original run; this private fixture changes only that one bit.
    a20source = out/'a20test-reset-deasserted.S'
    a20original = sources/'mabench/a20test.S'
    with a20source.open('x') as stream:
        stream.write(a20_no_reset(a20original.read_text()))
    pins[str(a20source)] = sha(a20source)
    save(out/'started.json', dict(pins=pins, cases=CASES, witnesses=WITNESSES,
        invocation=os.environ['INVOCATION_ID'], workers=32, sequential_goldens=True,
        profiles=[sorted(profile) for profile in profiles],
        oracle_scope={'differential': [case[1] for case in CASES if case[1] != 'pfetchlim'],
                      'precise_fault_witness_only': ['pfetchlim']}, a20_reset_bit_corrected=True))
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('VEN_', 'VTM_', 'TB_', 'QEMU_', 'AXI_', 'FP_'))}
    env.update(TMPDIR=str(out), PYTHONDONTWRITEBYTECODE='1')
    golden_lock = threading.Lock()

    def run(leaf, label, command, expected=0, latency=0):
        argv = ['timeout', '--signal=TERM', '--kill-after=3s', '60s', *map(str, command)]
        save(leaf/(label+'.command.json'), argv)
        with (leaf/(label+'.stdout')).open('x') as stdout, (leaf/(label+'.stderr')).open('x') as stderr:
            native = subprocess.run(argv, env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)),
                                    stdout=stdout, stderr=stderr)
        save(leaf/(label+'.exit.json'), dict(native_exit=native.returncode))
        assert native.returncode == expected, (leaf.name, label, native.returncode, expected)
        return (leaf/(label+'.stdout')).read_text(), (leaf/(label+'.stderr')).read_text()

    def check(case):
        folder, name, linker, cap, x87 = case
        leaf = out/name
        leaf.mkdir()
        obj, elf, image = (leaf/('fixture.'+suffix) for suffix in ('o', 'elf', 'bin'))
        assembly = a20source if name == 'a20test' else sources/folder/(name+'.S')
        run(leaf, 'assemble', ['gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic',
            '-fno-pie', '-Wall', '-c', assembly, '-o', obj])
        run(leaf, 'link', ['ld', '-m', 'elf_i386', '-T', sources/folder/linker, obj, '-o', elf])
        run(leaf, 'binary', ['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', elf, image])
        assert image.stat().st_size == 65536
        stdout, stderr = run(leaf, 'qemu-free', [qemu, '-machine', 'pc', '-cpu', 'pentium', '-m', '64',
            '-bios', image, '-display', 'none', '-serial', 'stdio', '-monitor', 'none',
            '-no-reboot', '-no-shutdown', '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'],
            135 if name == 'pfetchlim' else 133)
        if name in ('a20test', 'a20cmdtest'):
            expected = A20 if name == 'a20test' else A20CMD
            assert (stdout+stderr).count(expected) == 1
        extra = ['--x87'] if x87 else []
        golden = None
        if name != 'pfetchlim':
            with golden_lock:
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1', 0))
                    port = sock.getsockname()[1]
                run(leaf, 'golden', [sys.executable, '-B', REPO/'verif/qemu-trace/gen_trace.py',
                    '--qemu', qemu, '--system', *extra, '--cpu', 'pentium', '--image', image,
                    '--image-mode', 'bios', '--out', leaf/'golden.vtrace', '--max-insn', cap, '--port', port])
            golden = tracefmt.read_trace(str(leaf/'golden.vtrace'))
            assert golden.sys and golden.x87 == x87 and 0 < len(golden.records) < cap
            witness(name, golden)
        measurements, failures = [], []
        for latency in (0, 7):
            both = {}
            for label, model in models.items():
                streams = {}
                clocks = []
                for mode in ('cycle-func', 'cycle'):
                    stem = f'{label}-lat{latency}-{mode}'
                    path = leaf/(stem+'.vtrace')
                    stdout, stderr = run(leaf, stem, [model, '--system', '--cosim', '--l1-axi',
                        '--'+mode, *extra, '--image', image, '--out', path, '--max-insn', cap,
                        '--max-cycles', '3000000', '--quiesce', '8000', '+ven_faultlog'], 133, latency)
                    trace = tracefmt.read_trace(str(path))
                    assert 0 < len(trace.records) < cap
                    assert [row['n'] for row in trace.records] == list(range(len(trace.records)))
                    if golden is not None:
                        assert [row['pc'] for row in trace.records] == [row['pc'] for row in golden.records]
                    assert not grade.native.FATAL.search(stdout+stderr)
                    witness(name, trace, stdout+stderr, architectural=mode == 'cycle-func')
                    if name == 'pfetchlim':
                        fetch_fault_witness(stdout)
                    stops = re.findall(r'after (\d+) retired in (\d+) clocks', stderr)
                    assert len(stops) == 1 and int(stops[0][0]) == len(trace.records)
                    clocks.append(int(stops[0][1]))
                    if mode == 'cycle-func':
                        check_native = grade.grade_fp_native if x87 else grade.native.grade_native
                        check_native(trace, stdout, stderr, 133, 133, cap)
                        if golden is not None:
                            with (leaf/(stem+'-diff.log')).open('x') as log:
                                result = compare.compare_func(golden, trace, x87, 0xffffffff, False, 20, log, sys_both=True)
                            if result:
                                failures.append(dict(model=label, latency=latency, error='full QEMU architectural mismatch'))
                    else:
                        assert trace.mode == 'cycle'
                    streams[mode] = trace.records
                assert clocks[0] == clocks[1]
                assert [row['pc'] for row in streams['cycle-func']] == [row['pc'] for row in streams['cycle']]
                both[label] = streams
                measurements.append(dict(case=name, model=label, latency=latency,
                    records=len(streams['cycle']), clocks=clocks[0],
                    qemu_differential=golden is not None,
                    paired_v=sum(row.get('pipe') == 'V' and row.get('paired') for row in streams['cycle'])))
            if both['control'] != both['candidate']:
                failures.append(dict(latency=latency, error='complete parent/candidate state or cycle difference'))
        save(leaf/'closed.json', dict(passed=not failures, measurements=measurements,
                                     errors=failures, image_sha256=sha(image)))
        return measurements, failures

    result = dict(passed=False, errors=[], measurements=[], gameplay_ipc=None,
                  standard_suite=False, hardware_acceptance=False, smm_tested=False, reset_sweep=False)
    begin = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
        jobs = {pool.submit(check, case): case[1] for case in CASES}
        for job in concurrent.futures.as_completed(jobs):
            try:
                measurements, failures = job.result()
                result['measurements'].extend(measurements)
                result['errors'].extend(dict(case=jobs[job], **error) for error in failures)
            except Exception as error:
                result['errors'].append(dict(case=jobs[job], error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=all(sha(path) == digest for path, digest in pins.items()),
                  seconds=time.monotonic()-begin)
    result['passed'] = not result['errors'] and len(result['measurements']) == 36 and result['pins_unchanged']
    save(out/'closed.json', result)
    print(json.dumps({key: value for key, value in result.items() if key != 'measurements'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
