#!/usr/bin/env python3
"""Build the byte-exact fragment correction in the unchanged full-PC platform.

This is a diagnostic successor, not standard-suite or FPGA acceptance. Recheck
all shared RTL, actual complete directed traces, and the unchanged canonical
gate before building. Do not copy historical proof trees into every new pin set.
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
sys.path[:0] = [str(REPO/'verif/issue_uv'), str(REPO/'verif/diff')]
from build_fragment_exact_core import sha, load, save, stable
from prepare_fragment_exact_reads import transform
import tracefmt

PARENT_MODEL = 'c9d73a0643a759e411f2dbfcecd2425df247349b42e68a4b01eb3ff4edc6cb47'
CORE_MODEL = 'e4ed9c0c01f53b96fc7da451695feea84b9eabf0891589107711300f042f65c8'
CHANGE = 'rtl/core/core.sv'


def directed_proof(proof, pins):
    def read(path):
        pins[str(path)] = sha(path)
        return load(path)
    core = proof/'exact-core-r1'
    built, prepared = read(core/'build-closed.json'), read(core/'prepared.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(core/'obj/tb_ventium') == CORE_MODEL
    assert stable(prepared['pins'])
    pins.update(prepared['pins'])
    matrix = read(proof/'exact-system-r1/closed.json')
    assert matrix['passed'] and len(matrix['cases']) == 12 and stable(matrix['pins'])
    assert all(row['passed'] and len(row['measurements']) == 2 for row in matrix['cases'])
    bus = read(proof/'exact-bus-r1/closed.json')
    assert bus['passed'] and len(bus['cases']) == 6 and stable(bus['pins'])
    pins.update(matrix['pins']); pins.update(bus['pins'])
    from observe_fragment_exact_core import check_bytes
    for case in bus['cases']:
        leaf = proof/'exact-bus-r1'/(case['name']+f"-lat{case['latency']}")
        observations = leaf/'observations.json'
        assert sha(observations) == case['observations_sha256']
        assert check_bytes(read(observations), int(case['name'][5])) == case['transfers']

    broad = proof/'exact-system-broad-r1'
    closed, started = read(broad/'closed.json'), read(broad/'started.json')
    assert closed['pins_unchanged'] and stable(started['pins'])
    pins.update(started['pins'])
    assert len(closed['measurements']) == 36
    expected = {(name, latency, 'complete parent/candidate state or cycle difference')
                for name in ('pxfrag', 'pxc04', 'pxc04e') for latency in (0, 7)}
    assert {(r['case'], r['latency'], r['error']) for r in closed['errors']} == expected
    # The original equivalence gate remains FAIL. Reopen every complete
    # architectural stream independently and report—not hide—the timing deltas.
    differences = []
    for row in closed['measurements']:
        if row['model'] != 'candidate':
            continue
        name, latency = row['case'], row['latency']
        old = next(r for r in closed['measurements']
                   if r['case'] == name and r['latency'] == latency and r['model'] == 'control')
        streams = []
        for who in ('control', 'candidate'):
            path = broad/name/f'{who}-lat{latency}-cycle-func.vtrace'
            pins[str(path)] = sha(path)
            streams.append(tracefmt.read_trace(str(path)).records)
        assert streams[0] == streams[1] and len(streams[1]) == row['records']
        assert row['clocks'] <= old['clocks'], (name, 'unexpected slowdown')
        differences.append(dict(case=name, latency=latency,
                                clock_delta=row['clocks']-old['clocks']))
    for name, count in (('exact-fp-r1/matrix', 288), ('exact-smm-r1', 8), ('exact-rep-smi-r1', 4)):
        closed, started = read(proof/name/'closed.json'), read(proof/name/'started.json')
        assert closed['passed'] and closed['pins_unchanged'] and not closed['errors']
        assert len(closed['measurements']) == count and stable(started['pins'])
        pins.update(started['pins'])
    return differences


def prepare(parent, proof, root):
    assert not root.exists()
    old, closed = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    assert closed['binary_sha256'] == sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == PARENT_MODEL
    pins = {}
    changes = directed_proof(proof, pins)
    core = proof/'exact-core-r1/candidate'
    source = parent/'source'
    files = sorted(p for p in source.rglob('*') if p.is_file())
    for path in files:
        assert sha(path) == old['pins'][str(path)]
        pins[str(path)] = sha(path)
    fixed = transform((source/CHANGE).read_text(), (source/'rtl/core/core_bus_driver.svh').read_text())
    assert fixed == (core/CHANGE).read_text()
    shared = [str(p.relative_to(source)) for p in files
              if p.relative_to(source).parts[0] in ('rtl','fp_shared')
              and (core/p.relative_to(source)).is_file()]
    assert len(shared) == 102
    assert all(sha(source/name) == sha(core/name) for name in shared if name != CHANGE)
    root.mkdir(); shutil.copytree(source, root/'source')
    shutil.copyfile(core/CHANGE, root/'source'/CHANGE)
    assert all(sha(root/'source'/name) == sha(core/name) for name in shared)
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts) == 1
    host = root/'source/ao486-sim/ven'/('sim_fragment_exact_'+root.parent.name.split('.')[-1].lower()+'.cpp')
    shutil.copyfile(hosts[0], host)
    command = [s.replace(str(parent), str(root)) for s in old['command']]
    command = [str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    definitions = {s[2:] for s in command if s.startswith('-D')} | {s[8:] for s in command if s.startswith('+define+')}
    assert len(definitions) == 154 and '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (root/'defines.txt').write_text('\n'.join(sorted(definitions))+'\n')
    # Preserve nonlocal C++ dependencies as well as every copied input.
    dep = parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for word in dep.read_text().replace('\\\n', ' ').split()[1:]:
        path = Path(word)
        if path.is_absolute(): pins[str(path)] = sha(path)
    for path in (*files, *(p for p in (root/'source').rglob('*') if p.is_file()),
                 Path(__file__), root/'defines.txt', parent/'build-started.json',
                 parent/'build-closed.json', parent/'build.log', parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted'):
        pins[str(path)] = sha(path)
    assert stable(pins)
    save(root/'prepared.json', dict(command=command, pins=pins, changes=[CHANGE],
        added_defines=[], parent=str(parent), proof=str(proof), host=str(host),
        intersecting_rtl_sources=shared, parent_model=PARENT_MODEL, directed_model=CORE_MODEL,
        broad_architectural_streams_identical=True, broad_equivalence_gate_passed=False,
        broad_cycle_deltas=changes, canonical_gate_passed=False, qualification='UNQUALIFIED'))


def build(root):
    before = load(root/'prepared.json'); proof = Path(before['proof'])
    assert stable(before['pins']) and os.environ.get('INVOCATION_ID')
    assert not (root/'build-started.json').exists()
    verified = load(proof/'exact-core-r1/verify-closed.json')
    assert verified['pins_unchanged'] and all(row['same_records'] for row in verified['deltas'])
    assert len(verified['deltas']) == 20 and not verified['masks_or_goldens_or_bands_changed']
    before['pins'][str(proof/'exact-core-r1/verify-closed.json')] = sha(proof/'exact-core-r1/verify-closed.json')
    before.update(canonical_gate_passed=verified['canonical_gate_passed'], invocation=os.environ['INVOCATION_ID'])
    save(root/'build-started.json', before)
    env = dict(os.environ, CCACHE_DISABLE='1', PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(root),
        VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32', VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32',
        VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator')
    result = dict(passed=False, errors=[], gameplay_ipc=None, standard_suite=False, qualification='UNQUALIFIED')
    begin = time.monotonic()
    try:
        with (root/'build.log').open('x') as log:
            child = subprocess.run(before['command'], cwd=root/'source', env=env,
                                   stdout=log, stderr=subprocess.STDOUT, timeout=660)
        result['native_exit'] = child.returncode
        def warnings(path):
            return Counter(re.findall(r'^%Warning-(?:IMPLICIT|PINMISSING|UNDRIVEN|MULTIDRIVEN|LATCH|UNOPTFLAT):.*$', path.read_text(), re.M))
        expected = warnings(Path(before['parent'])/'build.log')
        assert warnings(root/'build.log') == expected and sum(expected.values()) == 98
        assert child.returncode == 0
        obj = root/'obj1-speed-q16-parentpolicy'; host = Path(before['host'])
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
    result.update(inputs_unchanged=stable(before['pins']), seconds=time.monotonic()-begin)
    result['passed'] &= result['inputs_unchanged']
    save(root/'build-closed.json', result); print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


def main():
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
        return 0
    return build(root)


if __name__ == '__main__':
    raise SystemExit(main())
