#!/usr/bin/env python3
"""Carry the descriptor/readiness fixes into a source-matched full-PC model.

The original platform, compiler command, defines and transport remain unchanged.
Directed A/B passes permit this diagnostic build, not FPGA/release acceptance.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

REPO = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(REPO/'verif/issue_uv'), str(REPO/'verif/l1')]
from build_bus_cancel_core import sha, load, save, stable
from prepare_descriptor_read_extent import transform as descriptor
from prepare_pair_ready_cofactor import transform as readiness

PARENT_MODEL = 'c52a221ecdc0ada4671c8f8d9e27bfd1be441a85b11cabcc610999f33ed75d75'
CORE_MODEL = '64e997d504e7f73fcd1f6b5e524a68cb6f901bf88f44b97fb613dfa1adf9d055'
CHANGES = ['rtl/core/core.sv', 'rtl/core/core_bus_driver.svh', 'rtl/mem/ven_l1d.sv']


def prepare(parent, proof, root):
    assert not root.exists()
    old, closed = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    assert closed['binary_sha256'] == sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == PARENT_MODEL
    core = proof/'core-r1'
    built, prepared = load(core/'build-closed.json'), load(core/'prepared.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(core/'obj/tb_ventium') == CORE_MODEL
    assert stable(prepared['pins'])
    pins = {}
    for name in ('memory-r1', 'store-r1', 'fp-r1/matrix'):
        checked = load(proof/name/'closed.json')
        before = load(proof/name/'started.json')
        assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
        assert len(checked['measurements']) == 288 and stable(before['pins'])
        assert before['models']['candidate'] == str((core/'obj/tb_ventium').resolve())
        if name != 'fp-r1/matrix': assert checked['memory_v_retirements'] > 0
        pins.update(before['pins'])
        for file in ('started.json','closed.json'):
            pins[str(proof/name/file)] = sha(proof/name/file)
    source = parent/'source'
    files = sorted(p for p in source.rglob('*') if p.is_file())
    assert all(not p.is_symlink() and sha(p) == old['pins'][str(p)] for p in files)
    expected = [*descriptor(*((source/p).read_text() for p in CHANGES[:2])),
                readiness((source/CHANGES[2]).read_text())]
    assert expected == [(core/'candidate'/p).read_text() for p in CHANGES]
    shared = [str(p.relative_to(source)) for p in files
              if p.relative_to(source).parts[0] in ('rtl','fp_shared')
              and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared) == 102
    assert [p for p in shared if sha(source/p) != sha(core/'candidate'/p)] == CHANGES
    root.mkdir(); shutil.copytree(source, root/'source')
    for p in CHANGES: shutil.copyfile(core/'candidate'/p, root/'source'/p)
    assert all(sha(root/'source'/p) == sha(core/'candidate'/p) for p in shared)
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts) == 1
    host = root/'source/ao486-sim/ven'/('sim_pair_ready_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(hosts[0], host)
    command = [s.replace(str(parent), str(root)) for s in old['command']]
    command = [str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    defs = [s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs) == len(set(defs)) == 154
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (root/'defines.txt').write_text('\n'.join(sorted(defs))+'\n')
    dep = parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dep.read_text().replace('\\\n',' ').split()[1:]:
        path = Path(name)
        if path.is_absolute(): pins[str(path)] = sha(path)
    for p in (*files, *(p for p in (root/'source').rglob('*') if p.is_file()),
        Path(__file__), REPO/'verif/l1/prepare_pair_ready_cofactor.py',
        REPO/'verif/issue_uv/prepare_descriptor_read_extent.py', root/'defines.txt',
        parent/'build-started.json', parent/'build-closed.json', parent/'build.log',
        core/'build-started.json', core/'build-closed.json', core/'prepared.json', core/'obj/tb_ventium'):
        pins[str(p)] = sha(p)
    assert stable(pins)
    save(root/'prepared.json', dict(command=command, pins=pins, changes=CHANGES,
        added_defines=[], parent=str(parent), proof=str(proof), host=str(host),
        intersecting_rtl_sources=shared, parent_model=PARENT_MODEL, directed_model=CORE_MODEL,
        canonical_gate_passed=False, qualification='UNQUALIFIED'))


def build(root):
    before = load(root/'prepared.json')
    assert stable(before['pins']) and os.environ.get('INVOCATION_ID')
    assert not (root/'build-started.json').exists()
    gate = Path(before['proof'])/'core-r1/verify-closed.json'
    checked = load(gate)
    assert checked['pins_unchanged'] and not checked['masks_or_goldens_or_bands_changed']
    assert len(checked['deltas']) == 20 and all(row['same_records'] for row in checked['deltas'])
    before['pins'][str(gate)] = sha(gate)
    before.update(canonical_gate_passed=checked['canonical_gate_passed'], invocation=os.environ['INVOCATION_ID'])
    save(root/'build-started.json', before)
    env = dict(os.environ, CCACHE_DISABLE='1', PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(root),
        VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32', VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32',
        VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator')
    result = dict(passed=False, errors=[], gameplay_ipc=None, standard_suite=False, qualification='UNQUALIFIED')
    start = time.monotonic()
    try:
        with (root/'build.log').open('x') as f:
            child = subprocess.run(before['command'], cwd=root/'source', env=env,
                                   stdout=f, stderr=subprocess.STDOUT, timeout=660)
        result['native_exit'] = child.returncode
        def warnings(path):
            return Counter(re.findall(r'^%Warning-(?:IMPLICIT|PINMISSING|UNDRIVEN|MULTIDRIVEN|LATCH|UNOPTFLAT):.*$', path.read_text(), re.M))
        expected = warnings(Path(before['parent'])/'build.log')
        assert warnings(root/'build.log') == expected and sum(expected.values()) == 98
        assert child.returncode == 0
        obj, host = root/'obj1-speed-q16-parentpolicy', Path(before['host'])
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n',' ').split()
                   if Path(s).name == 'Vsystem___024root.h']
        assert len(headers) == 1
        header = headers[0] if headers[0].is_absolute() else obj/headers[0]
        assert header.resolve() == (obj/'Vsystem___024root.h').resolve()
        result.update(passed=True, structural_warnings_unchanged=True, structural_debt_count=98,
                      binary_sha256=sha(obj/'ao486sim_board_posted'), harness_header=str(header))
    except Exception as error:
        result['errors'].append(dict(error=repr(error), traceback=traceback.format_exc()))
    result.update(inputs_unchanged=stable(before['pins']), seconds=time.monotonic()-start)
    result['passed'] &= result['inputs_unchanged']
    save(root/'build-closed.json', result); print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare','build'))
    parser.add_argument('--parent', type=Path); parser.add_argument('--proof', type=Path)
    parser.add_argument('--out', type=Path, required=True); args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True); root = args.out.resolve()
    assert __debug__ and root != scratch and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert args.parent and args.proof
        prepare(args.parent.resolve(strict=True), args.proof.resolve(strict=True), root)
        print(json.dumps(dict(prepared=str(root), compiler_started=False)), flush=True)
    else:
        raise SystemExit(build(root))
