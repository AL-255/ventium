#!/usr/bin/env python3
"""Cold SMI/save-map/RSM tests on existing UV-fast parent/candidate models.

Guest APIC SMI only: no state injection or snapshot. SMM is witness-graded,
not QEMU single-step differential. Free-running QEMU must independently exit.
This does not claim the old linear-I-cache way-placement probe on the new
physical L1 configuration; it checks architectural remapping and restore.
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import traceback

from run_bus_cancel_system import REPO, sha, save, tracefmt, grade

CASES = (('psmm', 'psmm', 'psmm.ld'), ('prsmflush', 'prsmflush_smm', 'prsmflush.ld'))
SAVED = dict(sent_smm_ran=0x5a4d5a4d, sent_resumed=0x52455421, sent_intact=0x5a4d900d,
             save_ebx=0x5a4d900d, save_cs_sel=8, save_smbase=0x30000, save_dr7=0xf0400,
             save_tr=0x18, save_tr_base=0x3000, sent_dr7=0xf0400)
FLUSH = dict(edi=0x5a4d0002, esi=0x5a4d0001, ebp=0x5a4d900d, ebx=0x52455421)


def check_save(dump):
    values = {key: int(value, 16) for key, value in dump.items() if isinstance(value, str)}
    for key, expected in SAVED.items():
        assert values[key] == expected, (key, values[key], expected)
    assert values['save_cr0'] & 1
    assert 0xf0000 <= values['save_eip'] <= 0xfffff
    assert values['save_dr6'] & 0xffff0ff0 == 0xffff0ff0


def check_trace(name, records):
    assert len(records) > 300
    def value(row, key): return int(row[key], 0)
    entries = [index for index, row in enumerate(records)
               if value(row, 'cs') == 0x3000 and not (value(row, 'cr0') & 0x80000001)
               and value(row, 'pc') == 0x8000]
    assert len(entries) == (1 if name == 'psmm' else 2), ('SMM entry count', name, entries)
    for entry in entries:
        restored = next((row for row in records[entry+1:]
                         if value(row, 'cs') == 8 and value(row, 'cr0') & 1), None)
        assert restored is not None and value(restored, 'ebx') == 0x5a4d900d
    if name == 'prsmflush_smm':
        for key, expected in FLUSH.items():
            assert value(records[-1], key) == expected, (key, records[-1][key])
        assert value(records[-1], 'edx') >> 16 == 0x600d


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
    profiles, pins = [], {}
    for model in models.values():
        stamp = model.parent/'Vventium_top__verFiles.dat'
        command = next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
        defs = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command
        assert {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SEG_ENFORCE', 'VEN_SYS_FASTPATH_RELOC',
                'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT'} <= defs
        assert not {'SYNTHESIS', 'VTM_NO_DPI', 'VEN_SYS_FASTPATH_ALL'} & defs
        profiles.append(defs)
        pins.update({str(path): sha(path) for path in (model, stamp)})
    assert profiles[0] == profiles[1]
    sources = REPO/'verif/sys/tests'
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for folder, name, linker in CASES:
        for path in (sources/folder/(name+'.S'), sources/folder/linker):
            pins[str(path)] = sha(path)
    for path in (Path(__file__), Path(__file__).with_name('run_bus_cancel_system.py'),
                 Path(__file__).with_name('run-fp-payload-ab.py'), REPO/'verif/diff/tracefmt.py',
                 REPO/'verif/sys/run-native-system.py', REPO/'verif/sys/run-prsmflush-gate.sh',
                 sources/'psmm/psmm-rtl-selfcheck.py', qemu):
        pins[str(path)] = sha(path)
    out.mkdir()
    save(out/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        cases=CASES, qemu_single_step=False, state_injection=False, snapshots=False))
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('VEN_', 'VTM_', 'TB_', 'QEMU_', 'AXI_', 'FP_'))}
    env.update(TMPDIR=str(out), PYTHONDONTWRITEBYTECODE='1')

    def run(leaf, label, command, expected=0, latency=0):
        argv = ['timeout', '--kill-after=3s', '60s', *map(str, command)]
        save(leaf/(label+'.command.json'), argv)
        with (leaf/(label+'.stdout')).open('x') as stdout, (leaf/(label+'.stderr')).open('x') as stderr:
            native = subprocess.run(argv, env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)),
                                    stdout=stdout, stderr=stderr)
        save(leaf/(label+'.exit.json'), dict(native_exit=native.returncode))
        assert native.returncode == expected, (leaf.name, label, native.returncode, expected)
        return (leaf/(label+'.stdout')).read_text(), (leaf/(label+'.stderr')).read_text()

    def check(case):
        folder, name, linker = case
        leaf = out/name
        leaf.mkdir()
        obj, elf, image = (leaf/('fixture.'+suffix) for suffix in ('o', 'elf', 'bin'))
        run(leaf, 'assemble', ['gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic', '-fno-pie',
            '-Wall', '-c', sources/folder/(name+'.S'), '-o', obj])
        run(leaf, 'link', ['ld', '-m', 'elf_i386', '-T', sources/folder/linker, obj, '-o', elf])
        run(leaf, 'binary', ['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', elf, image])
        assert image.stat().st_size == 65536
        run(leaf, 'qemu-free', [qemu, '-machine', 'pc', '-cpu', 'pentium', '-m', '64', '-bios', image,
            '-display', 'none', '-serial', 'none', '-monitor', 'none', '-no-reboot', '-no-shutdown',
            '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'], 133)
        rows = []
        for latency in (0, 7):
            both, dumps = {}, {}
            for label, model in models.items():
                streams, clocks = {}, []
                for mode in ('cycle-func', 'cycle'):
                    stem = f'{label}-lat{latency}-{mode}'
                    path, dump = leaf/(stem+'.vtrace'), leaf/(stem+'.smm.json')
                    stdout, stderr = run(leaf, stem, [model, '--system', '--cosim', '--l1-axi', '--'+mode,
                        '--image', image, '--out', path, '--max-insn', '12000', '--max-cycles', '3000000',
                        '--quiesce', '8000', '--smm-dump', dump, '--smbase', '0x30000', '+ven_faultlog'], 133, latency)
                    trace = tracefmt.read_trace(str(path))
                    assert 300 < len(trace.records) < 12000
                    assert [row['n'] for row in trace.records] == list(range(len(trace.records)))
                    assert not grade.native.FATAL.search(stdout+stderr)
                    assert not re.search(r'^\[FAULT\]', stdout, re.M)
                    stops = re.findall(r'after (\d+) retired in (\d+) clocks', stderr)
                    assert len(stops) == 1 and int(stops[0][0]) == len(trace.records)
                    clocks.append(int(stops[0][1]))
                    if mode == 'cycle-func':
                        grade.native.grade_native(trace, stdout, stderr, 133, 133, 12000)
                        check_trace(name, trace.records)
                    else:
                        assert trace.mode == 'cycle'
                    observed = json.loads(dump.read_text())
                    if name == 'psmm':
                        check_save(observed)
                    dumps[label, mode] = observed
                    streams[mode] = trace.records
                assert clocks[0] == clocks[1]
                assert [row['pc'] for row in streams['cycle-func']] == [row['pc'] for row in streams['cycle']]
                both[label] = streams
                rows.append(dict(case=name, model=label, latency=latency,
                                 clocks=clocks[0], records=len(streams['cycle'])))
            assert both['control'] == both['candidate'], (name, latency, 'architectural/cycle difference')
            for mode in ('cycle-func', 'cycle'):
                assert dumps['control', mode] == dumps['candidate', mode], 'save-map difference'
        save(leaf/'closed.json', dict(passed=True, measurements=rows, image_sha256=sha(image)))
        return rows

    result = dict(passed=False, errors=[], measurements=[], qemu_single_step=False,
                  gameplay_ipc=None, standard_suite=False, hardware_acceptance=False, reset_sweep=False)
    began = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        jobs = {pool.submit(check, case): case[1] for case in CASES}
        for job in concurrent.futures.as_completed(jobs):
            try:
                result['measurements'].extend(job.result())
            except Exception as error:
                result['errors'].append(dict(case=jobs[job], error=repr(error), traceback=traceback.format_exc()))
    result.update(pins_unchanged=all(sha(path) == digest for path, digest in pins.items()), seconds=time.monotonic()-began)
    result['passed'] = not result['errors'] and len(result['measurements']) == 8 and result['pins_unchanged']
    save(out/'closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
