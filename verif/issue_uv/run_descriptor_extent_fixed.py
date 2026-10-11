#!/usr/bin/env python3
"""Require the descriptor correction to match complete original QEMU traces.

Replay the twelve excess-read reproducers and twelve genuine crossing/fault
fixtures. Architectural traces are untrimmed, cycle traces retain actual U/V
retirements, and neither snapshots nor guest debugger STEP is used.
"""
import argparse
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

import build_descriptor_extent_core as builder
import prepare_descriptor_read_extent as patch

REPO = builder.REPO
sys.path.insert(0, str(REPO/'verif/diff'))
import compare
import tracefmt

sha, save, load, stable = builder.sha, builder.save, builder.load, builder.stable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('build', 'proof', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    build, proof, out = args.build.resolve(strict=True), args.proof.resolve(strict=True), args.out.resolve()
    assert __debug__ and os.environ.get('INVOCATION_ID')
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert out.is_relative_to(scratch) and not out.exists() and shutil.disk_usage(scratch).free > 4*1024**3
    prepared, built = load(build/'prepared.json'), load(build/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0 and stable(prepared['pins'])
    model = build/'obj/tb_ventium'
    assert sha(model) == built['binary_sha256'] and prepared['changes'] == builder.CHANGES
    parent = Path(prepared['parent'])
    fixed = patch.transform(*((parent/'candidate'/p).read_text() for p in builder.CHANGES))
    assert fixed == tuple((build/'candidate'/p).read_text() for p in builder.CHANGES)
    stamp = build/'obj/Vventium_top__verFiles.dat'
    command = next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
    definitions = set(re.findall(r'\+define\+(\w+)', command))
    assert definitions == set(prepared['definitions']) and len(definitions) == 150
    assert '--assert' in command and not {'SYNTHESIS', 'VTM_NO_DPI'} & definitions
    repro = proof/'descriptor-extent-r1'
    assert sha(repro/'closed.json') == builder.REPRO
    assert load(repro/'closed.json')['investigation_completed']
    matrix = load(proof/'exact-system-r1/closed.json')
    assert matrix['passed'] and matrix['pins_unchanged']
    native_path = REPO/'verif/sys/run-native-system.py'
    spec = importlib.util.spec_from_file_location('extent_fixed_native', native_path)
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    pins = {str(p): sha(p) for p in (model, stamp, Path(__file__), Path(builder.__file__),
        Path(patch.__file__), Path(compare.__file__), Path(tracefmt.__file__), native_path,
        build/'prepared.json', build/'build-closed.json', repro/'closed.json', proof/'exact-system-r1/closed.json')}
    cases = []
    for row in load(repro/'closed.json')['rows']:
        name = row['case']
        image, golden = repro/name/'fixture.bin', repro/name/'golden.vtrace'
        assert sha(image) == row['image_sha256']
        cases.append((name, image, golden, 'contained'))
    for row in matrix['cases']:
        name = row['name']
        image = proof/'abort-replacement-r1'/name/'fixture.bin'
        golden = proof/'exact-system-r1'/name/'golden.vtrace'
        cases.append((name, image, golden, 'crossing'))
    assert len(cases) == 24
    for _, image, golden, _ in cases:
        pins[str(image)] = sha(image)
        pins[str(golden)] = sha(golden)
    out.mkdir()
    save(out/'started.json', dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        model=built['binary_sha256'], affinity=sorted(os.sched_getaffinity(0)), definitions=sorted(definitions)))
    start = time.monotonic()
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'VTM_', 'TB_', 'AXI_', 'QEMU_'))}

    def check(case):
        name, image, golden_path, kind = case
        leaf = out/name
        leaf.mkdir()
        result = dict(case=name, passed=False, measurements=[], errors=[])
        try:
            golden = tracefmt.read_trace(str(golden_path))
            for latency in (0, 7):
                clocks = []
                for mode in ('cycle-func', 'cycle'):
                    label = f'lat{latency}-{mode}'
                    trace = leaf/(label+'.vtrace')
                    argv = ['timeout', '--signal=TERM', '--kill-after=2s', '30s', str(model),
                        '--system', '--cosim', '--l1-axi', '--'+mode, '--image', str(image),
                        '--out', str(trace), '--max-insn', '3000', '--max-cycles', '3000000',
                        '--quiesce', '8000', '+ven_faultlog']
                    save(leaf/(label+'.command.json'), argv)
                    with (leaf/(label+'.stdout')).open('x') as output, (leaf/(label+'.stderr')).open('x') as errors:
                        child = subprocess.run(argv, stdout=output, stderr=errors,
                            env={**env, 'AXI_RLAT': str(latency), 'AXI_WLAT': str(latency)})
                    save(leaf/(label+'.exit.json'), dict(native_exit=child.returncode, actual_wait=True))
                    assert child.returncode == 133
                    stdout, stderr = (leaf/(label+'.stdout')).read_text(), (leaf/(label+'.stderr')).read_text()
                    assert not native.FATAL.search(stdout+stderr)
                    got = tracefmt.read_trace(str(trace))
                    assert [r['pc'] for r in got.records] == [r['pc'] for r in golden.records]
                    clocks.append(int(re.findall(r'after \d+ retired in (\d+) clocks', stderr)[0]))
                    if mode == 'cycle-func':
                        native.grade_native(got, stdout, stderr, child.returncode, 133, 3000)
                        with (leaf/(label+'-diff.log')).open('x') as log:
                            assert compare.compare_func(golden, got, False, 0xffffffff, False, 20, log, sys_both=True) == 0
                        if kind == 'contained':
                            last = got.records[-1]
                            assert {k: tracefmt.parse_hex(last[k]) for k in ('ecx', 'ebx', 'ebp', 'esi')} == dict(ecx=0, ebx=0x2f, ebp=0x400000, esi=0)
                    else:
                        assert got.mode == 'cycle'
                        paired = sum(r.get('pipe') == 'V' and r.get('paired') for r in got.records)
                        assert paired > 0
                        result['measurements'].append(dict(latency=latency, clocks=clocks[-1],
                            records=len(got.records), paired_v=paired))
                assert clocks[0] == clocks[1]
            result['passed'] = True
        except Exception as error:
            result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
        save(leaf/'closed.json', result)
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        rows = list(pool.map(check, cases))
    unchanged = stable(pins)
    result = dict(passed=unchanged and all(r['passed'] for r in rows), cases=rows, pins=pins,
        pins_unchanged=unchanged, seconds=time.monotonic()-start, gameplay_ipc=None,
        standard_suite=False, canonical_gate_passed=False, physical_board=False)
    save(out/'closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k != 'pins'}), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
