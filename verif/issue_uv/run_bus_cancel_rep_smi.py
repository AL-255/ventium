#!/usr/bin/env python3
"""Exercise the actual MOVS source-owner cancellation using the original SMI gate.

No QEMU SMM differential is claimed. The existing self-check requires the
immediate ARM/CANCEL boundary, exact save-map and REP/SMM/RSM ordering.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback
from run_bus_cancel_system import REPO, sha, save, grade, tracefmt


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
        assert ' --assert ' in command and {'VEN_L1_AXI', 'VEN_FE_PIPE', 'VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT', 'VEN_REP_MOVS_CONT',
            'VEN_REP_MOVS_STREAM', 'VEN_REP_MOVS_LOAD_FUSE'} <= defs
        assert not {'SYNTHESIS', 'VTM_NO_DPI', 'VEN_SYS_FASTPATH_ALL', 'VEN_REP_STOS_STREAM'} & defs
        profiles.append(defs)
        pins.update({str(path): sha(path) for path in (model, stamp)})
    assert profiles[0] == profiles[1] and len(profiles[0]) == 150
    source = REPO/'verif/sys/tests/prepsmi'
    checker = source/'prepsmi-rtl-selfcheck.py'
    for path in (Path(__file__), Path(__file__).with_name('run_bus_cancel_system.py'),
                 Path(__file__).with_name('run-fp-payload-ab.py'), REPO/'verif/sys/run-native-system.py',
                 REPO/'verif/diff/tracefmt.py', source/'prepsmi.S', source/'prepsmi.ld', checker):
        pins[str(path)] = sha(path)
    out.mkdir()
    save(out/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
                                 qemu_differential=False, state_injection=False, snapshots=False))
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('VEN_', 'VTM_', 'TB_', 'QEMU_', 'AXI_', 'FP_'))}
    env.update(TMPDIR=str(out), PYTHONDONTWRITEBYTECODE='1')
    def run(label, command, expected=0, latency=0):
        argv = ['timeout', '--kill-after=3s', '60s', *map(str, command)]
        save(out/(label+'.command.json'), argv)
        with (out/(label+'.stdout')).open('x') as stdout, (out/(label+'.stderr')).open('x') as stderr:
            native = subprocess.run(argv, env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)),
                                    stdout=stdout, stderr=stderr)
        save(out/(label+'.exit.json'), dict(native_exit=native.returncode))
        assert native.returncode == expected, (label, native.returncode, expected)
        return (out/(label+'.stdout')).read_text(), (out/(label+'.stderr')).read_text()
    result = dict(passed=False, errors=[], measurements=[], gameplay_ipc=None,
                  standard_suite=False, hardware_acceptance=False, qemu_differential=False)
    begin = time.monotonic()
    try:
        obj, elf, image = (out/('fixture.'+suffix) for suffix in ('o', 'elf', 'bin'))
        run('assemble', ['gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic', '-fno-pie',
            '-DPREP_SMI_MOVS', '-Wall', '-c', source/'prepsmi.S', '-o', obj])
        run('link', ['ld', '-m', 'elf_i386', '-T', source/'prepsmi.ld', obj, '-o', elf])
        run('binary', ['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', elf, image])
        assert image.stat().st_size == 65536
        symbols = {parts[2]: int(parts[0], 16)
                   for line in subprocess.check_output(['nm', '-n', elf], text=True).splitlines()
                   if len(parts := line.split()) == 3 and parts[0] != 'U'}
        pc = symbols['rep_smi']
        assert pc & 31 == 19
        pins.update({str(path): sha(path) for path in (obj, elf, image)})
        for latency in (0, 7):
            both = {}
            for name, model in models.items():
                streams, clocks = {}, []
                for mode in ('cycle-func', 'cycle'):
                    label = f'{name}-lat{latency}-{mode}'
                    path, dump = out/(label+'.vtrace'), out/(label+'.smm.json')
                    stdout, stderr = run(label, [model, '--l1-axi', '--system', '--cosim', '--'+mode,
                        '--image', image, '--out', path, '--smm-dump', dump, '--smbase', '0x30000',
                        '--max-insn', '3000', '--max-cycles', '3000000', '--quiesce', '8000',
                        '+ven_repcontlog', '+ven_faultlog'], 133, latency)
                    trace = tracefmt.read_trace(str(path))
                    assert 0 < len(trace.records) < 3000
                    assert [row['n'] for row in trace.records] == list(range(len(trace.records)))
                    assert not grade.native.FATAL.search(stdout+stderr)
                    stops = re.findall(r'after (\d+) retired in (\d+) clocks', stderr)
                    assert len(stops) == 1 and int(stops[0][0]) == len(trace.records)
                    clocks.append(int(stops[0][1]))
                    if mode == 'cycle-func':
                        grade.native.grade_native(trace, stdout, stderr, 133, 133, 3000)
                        run(label+'-boundary-check', [sys.executable, '-B', checker, path, dump,
                            out/(label+'.stdout'), hex(pc), '0', '1', '1'])
                    else:
                        assert trace.mode == 'cycle'
                    streams[mode] = trace.records
                    streams[mode+'-save-map'] = json.loads(dump.read_text())
                assert clocks[0] == clocks[1]
                assert [row['pc'] for row in streams['cycle-func']] == [row['pc'] for row in streams['cycle']]
                both[name] = streams
                result['measurements'].append(dict(model=name, latency=latency, clocks=clocks[0],
                                                   records=len(streams['cycle'])))
            assert both['control'] == both['candidate'], 'complete state/cycles/save-map A/B difference'
        result['passed'] = len(result['measurements']) == 4
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(pins=pins, pins_unchanged=all(sha(path) == digest for path, digest in pins.items()),
                  seconds=time.monotonic()-begin)
    result['passed'] &= result['pins_unchanged']
    save(out/'closed.json', result)
    print(json.dumps({key: value for key, value in result.items() if key != 'pins'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
