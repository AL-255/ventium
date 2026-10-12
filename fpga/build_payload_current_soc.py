#!/usr/bin/env python3
"""Carry the combined, directed-tested timing core into the full PC platform.

Preserve UV/fast mode, posted-16 transport, every shared source and all existing
defines; add only the payload-kind sideband. Canonical FAIL is never waived.
"""
import argparse
from collections import Counter
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import traceback

import build_pair_ready_soc as common

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/l1'))
import prepare_payload_current as recipe
import prepare_ic_fill_read_ack as ifill

sha, load, save, stable = common.sha, common.load, common.save, common.stable
PARENT_MODEL = 'd8c147fe0b1b1bc91c4c9e861298fae66cfee012a926532d02227d2d6469b1aa'
CORE_MODEL = 'fbe7b4e3b31c83396414de6802fe2e06dd4be0d4b039199dfc0f8e660154c8d6'
CHANGES = sorted(recipe.CURRENT)


def regression_pins(proof, core):
    """Check the successful native retries, not the process-starved first matrix."""
    pins, statistics = {}, {}
    for name, count in (('memory', 288), ('fp', 1536), ('integer', 1024)):
        folder = proof/('payload-current-'+name+'-r2')
        before, checked = load(folder/'started.json'), load(folder/'closed.json')
        assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
        assert len(checked['measurements']) == count and stable(before['pins'])
        assert before['models']['candidate'] == str(core/'obj/tb_ventium')
        rows = [r for r in checked['measurements'] if r['model'] == 'candidate']
        assert len(rows) == count//2
        paired = sum(r.get('paired_v', r.get('memory_v', 0)) for r in rows)
        assert paired > 0
        statistics[name] = dict(measurements=count, candidate_records=sum(r['records'] for r in rows), paired_v=paired)
        pins.update(before['pins'])
        for p in (folder/'started.json', folder/'closed.json'):
            pins[str(p)] = sha(p)
    folder = proof/'payload-current-held-r2'
    held, inputs = load(folder/'result.json'), load(folder/'inputs.json')
    assert held['passed'] and held['inputs_unchanged'] and not held['errors'] and len(held['cases']) == 48
    assert str(core/'obj/tb_ventium') in inputs and stable(inputs)
    statistics['held'] = dict(cases=48, candidate_records=sum(r['measurements']['candidate']['records'] for r in held['cases']))
    pins.update(inputs)
    for p in (folder/'result.json', folder/'inputs.json'):
        pins[str(p)] = sha(p)
    folder = proof/'payload-current-regressions-r1/faults'
    checked, before = load(folder/'closed.json'), load(folder/'started.json')
    child = load(folder.parent/'faults-exit.json')
    assert child['native_exit'] == 0 and checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert len(checked['measurements']) == 32 and before['models']['candidate'] == str(core/'obj/tb_ventium')
    assert all(not row[k]['timed_out'] and row[k]['native_exit'] == 0
               for row in checked['measurements'] for k in ('gate', 'complete_uv_compare'))
    assert stable(before['pins']) and all(sha(folder/p) == h for p,h in checked['artifacts'].items())
    pins.update(before['pins'])
    pins.update({str(folder/p): h for p,h in checked['artifacts'].items()})
    for p in (folder/'started.json', folder/'closed.json', folder.parent/'faults-exit.json'):
        pins[str(p)] = sha(p)
    statistics['faults'] = dict(measurements=32, candidate_records=sum(
        r['records'] for r in checked['measurements'] if r['model'] == 'candidate'))
    return pins, statistics


def prepare(parent, core, proof, root):
    assert not root.exists()
    old, closed = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    assert closed['binary_sha256'] == sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == PARENT_MODEL
    built, prepared = load(core/'build-closed.json'), load(core/'prepared.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(core/'obj/tb_ventium') == CORE_MODEL and stable(prepared['pins'])
    pins, statistics = regression_pins(proof, core)
    source = parent/'source'
    files = sorted(p for p in source.rglob('*') if p.is_file())
    assert all(not p.is_symlink() and sha(p) == old['pins'][str(p)] for p in files)
    current = {n: (source/n).read_text() for n in CHANGES}
    current['rtl/core/core.sv'] = ifill.transform(current['rtl/core/core.sv'])
    original = proof/'core-r1/candidate'
    changed = recipe.transform(current, {n: (original/n).read_text() for n in CHANGES})
    assert all(s == (core/'candidate'/n).read_text() for n,s in changed.items())
    shared = [str(p.relative_to(source)) for p in files
              if p.relative_to(source).parts[0] in ('rtl', 'fp_shared')
              and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared) == 102
    assert [p for p in shared if sha(source/p) != sha(core/'candidate'/p)] == CHANGES
    root.mkdir()
    shutil.copytree(source, root/'source')
    for name in CHANGES:
        shutil.copyfile(core/'candidate'/name, root/'source'/name)
    assert all(sha(root/'source'/p) == sha(core/'candidate'/p) for p in shared)
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts) == 1
    host = root/'source/ao486-sim/ven'/('sim_payload_current_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0], host)
    command = [s.replace(str(parent), str(root)) for s in old['command']]
    command = [str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    defs = [s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs) == len(set(defs)) == 154 and recipe.payload.FLAG not in defs
    command.insert(command.index('/tools/verilator/v5.046/bin/verilator')+1, '+define+'+recipe.payload.FLAG)
    defs.append(recipe.payload.FLAG)
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (root/'defines.txt').write_text('\n'.join(sorted(defs))+'\n')
    dep = parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dep.read_text().replace('\\\n', ' ').split()[1:]:
        path = Path(name)
        if path.is_absolute(): pins[str(path)] = sha(path)
    for path in (*files, *(p for p in (root/'source').rglob('*') if p.is_file()),
                 Path(__file__), Path(common.__file__), Path(recipe.__file__), Path(ifill.__file__),
                 root/'defines.txt', parent/'build-started.json', parent/'build-closed.json',
                 parent/'build.log', core/'build-started.json', core/'build-closed.json',
                 core/'prepared.json', core/'obj/tb_ventium'):
        pins[str(path)] = sha(path)
    assert stable(pins)
    save(root/'prepared.json', dict(command=command, pins=pins, changes=CHANGES,
        added_defines=[recipe.payload.FLAG], parent=str(parent), directed_core=str(core),
        proof=str(proof), host=str(host), intersecting_rtl_sources=shared, statistics=statistics,
        parent_model=PARENT_MODEL, directed_model=CORE_MODEL,
        canonical_gate_passed=False, qualification='UNQUALIFIED'))


def build(root):
    before = load(root/'prepared.json')
    assert stable(before['pins']) and os.environ.get('INVOCATION_ID')
    assert not (root/'build-started.json').exists()
    gate = Path(before['directed_core'])/'verify-closed.json'
    checked = load(gate)
    assert checked['pins_unchanged'] and not checked['masks_or_goldens_or_bands_changed']
    assert checked['canonical_gate_native_exit'] in (0, 2)
    assert len(checked['deltas']) == 20 and all(r['same_records'] for r in checked['deltas'])
    before['pins'][str(gate)] = sha(gate)
    before.update(canonical_gate_passed=checked['canonical_gate_passed'], invocation=os.environ['INVOCATION_ID'])
    save(root/'build-started.json', before)
    env = dict(os.environ, CCACHE_DISABLE='1', PYTHONDONTWRITEBYTECODE='1', TMPDIR=str(root),
        VENTIUM_BUILD_SCOPE_PROFILE='ipc_parallel32', VENTIUM_BUILD_SCOPE_UNIT='ventium-ipc-parallel32',
        VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator')
    result = dict(passed=False, errors=[], gameplay_ipc=None, standard_suite=False, qualification='UNQUALIFIED')
    start = time.monotonic()
    try:
        with (root/'build.log').open('x') as stream:
            child = subprocess.run(before['command'], cwd=root/'source', env=env,
                                   stdout=stream, stderr=subprocess.STDOUT, timeout=660)
        result['native_exit'] = child.returncode
        def warnings(path):
            return Counter(re.findall(r'^%Warning-(?:IMPLICIT|PINMISSING|UNDRIVEN|MULTIDRIVEN|LATCH|UNOPTFLAT):.*$', path.read_text(), re.M))
        expected = warnings(Path(before['parent'])/'build.log')
        assert warnings(root/'build.log') == expected and sum(expected.values()) == 98
        assert child.returncode == 0
        obj, host = root/'obj1-speed-q16-parentpolicy', Path(before['host'])
        assert (obj/(host.stem+'.o')).is_file()
        headers = [Path(s) for s in (obj/(host.stem+'.d')).read_text().replace('\\\n', ' ').split()
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
    save(root/'build-closed.json', result)
    print(result, flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('prepare', 'build'))
    for name in ('parent', 'core', 'proof'): ap.add_argument('--'+name, type=Path)
    ap.add_argument('--out', required=True, type=Path)
    args = ap.parse_args()
    scratch, root = Path('/home/yukidama/external/tmp').resolve(strict=True), args.out.resolve()
    assert __debug__ and root != scratch and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        assert args.parent and args.core and args.proof
        prepare(args.parent.resolve(strict=True), args.core.resolve(strict=True), args.proof.resolve(strict=True), root)
        print('Prepared source-matched PC; compiler not launched.', flush=True)
    else:
        raise SystemExit(build(root))
