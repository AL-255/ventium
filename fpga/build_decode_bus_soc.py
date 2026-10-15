"""Transfer the strict-MF repair and no-beat DECODE address cut into the PC.

All 102 shared HDL inputs must match the directed core. The older PC already
contains the FPREM repairs; none may be dropped to improve timing. This is an
unqualified experimental model, not a standard-suite or physical-board pass.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_payload_current_soc as base

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/fetchguard'))
import prepare_decode_bus_payload as recipe

sha, load, save, stable = base.sha, base.load, base.save, base.stable
PARENT_MODEL = '0a1f097ee98c816eef72fc432a17fe09e77d7912651c548ad14853512e8edc52'
CORE_MODEL = '30274adaf425f55835f21562d845b08bec4552d37f4e29fd35ae7d3a95cb0b25'
BUILDER = '9951c6768f0441d63a0dec66ad6b302afb019924fce529c9d034b1e41c01c8a3'
CHANGES = [recipe.FILE]
FLAG = 'VEN_X87_MF_STRICT'


def add_strict(command):
    result = list(command)
    defs = [s[2:] for s in result if s.startswith('-D')]+[s[8:] for s in result if s.startswith('+define+')]
    assert len(defs) == len(set(defs)) == 156 and FLAG not in defs
    result.insert(result.index('/tools/verilator/v5.046/bin/verilator')+1, '+define+'+FLAG)
    return result, defs+[FLAG]


def prepare(parent, core, proof, root):
    assert not root.exists() and sha(base.__file__) == BUILDER
    pins, statistics = {}, {}
    for name in ('decode-bus-boundary-r1', 'decode-bus-system-r1', 'decode-bus-func-r1', 'decode-bus-delivery-r1'):
        folder = proof/name
        before, checked = load(folder/'started.json'), load(folder/'closed.json')
        assert checked['pins_unchanged'] and not checked.get('errors') and stable(before['pins'])
        if name.endswith('delivery-r1'):
            assert checked['completed'] and checked['candidate_passed'] and len(checked['rows']) == 144
            assert all(r['passed'] and r['native']['actual_wait'] and r['native']['native_exit'] == 133 for r in checked['rows'])
            assert before['definitions']['branch'] == load(core/'build-started.json')['definitions']
            assert before['pins'][str(core/'obj/tb_ventium')] == CORE_MODEL
            statistics['delivery_executions'] = 144
        else:
            assert checked['passed']
        if name.endswith('boundary-r1'):
            assert len(checked['rows']) == 88 and checked['paired_v'] > 0 and checked['probe_witnesses'] > 0
            assert before['pins'][str(core/'obj/tb_ventium')] == CORE_MODEL
            statistics['boundary_records'] = checked['candidate_records']
        if name.endswith('func-r1'):
            assert len(checked['rows']) == 108 and all(r['passed'] and r['actual_wait'] and
                r['affinity_verified'] and r['native_worker_exit'] == 0 for r in checked['rows'])
            assert before['model'] == CORE_MODEL
            statistics['private_functional_passes'] = 108
        if name.endswith('system-r1'):
            assert len(checked['rows']) == 5 and all(r['passed'] and len(r['rows']) == 6 for r in checked['rows'])
            assert before['pins'][str(core/'obj/tb_ventium')] == CORE_MODEL
            statistics['system_fixtures'] = 5
        pins.update(before['pins'])
        for p in (folder/'started.json', folder/'closed.json'): pins[str(p)] = sha(p)
    before, built = load(core/'build-started.json'), load(core/'build-closed.json')
    assert built['passed'] and built['native_exit'] == 0 and built['pins_unchanged']
    assert sha(core/'obj/tb_ventium') == built['binary_sha256'] == CORE_MODEL
    assert stable(before['pins'])
    pins.update(before['pins'])
    old, closed = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert closed['passed'] and closed['native_exit'] == 0 and closed['inputs_unchanged']
    assert sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == closed['binary_sha256'] == PARENT_MODEL
    source = parent/'source'
    files = sorted(p for p in source.rglob('*') if p.is_file())
    assert not any(p.is_symlink() for p in source.rglob('*'))
    assert all(sha(p) == old['pins'][str(p)] for p in files)
    shared = [str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl', 'fp_shared')
              and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared) == 102
    assert [n for n in shared if sha(source/n) != sha(core/'candidate'/n)] == CHANGES
    assert recipe.transform((source/recipe.FILE).read_text()) == (core/'candidate'/recipe.FILE).read_text()
    for n, digest in {
        'rtl/fpu/fpu_srt_div.sv': '480f5f23d9c151ce6ca0df243e449c2446e435a1c556308c359d3cc652742fd2',
        'fp_shared/ven_fp_top.sv': '0cdf1129c030bcd2b21e73400fafe20cb6192cad5376358c90f7e52c7a0e796c'
    }.items():
        assert sha(source/n) == sha(core/'candidate'/n) == digest
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts) == 1 and stable(pins)
    root.mkdir()
    shutil.copytree(source, root/'source')
    shutil.copyfile(core/'candidate'/recipe.FILE, root/'source'/recipe.FILE)
    assert all(sha(root/'source'/n) == sha(core/'candidate'/n) for n in shared)
    host = root/'source/ao486-sim/ven'/('sim_decode_bus_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0], host)
    command = [s.replace(str(parent), str(root)) for s in old['command']]
    command = [str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    command, defs = add_strict(command)
    assert set(defs)-{FLAG} == set((parent/'defines.txt').read_text().splitlines())
    assert command[:2] == [str(REPO/'tools/build_scope.sh'), '--'] and '600s' in command
    assert 'MemoryMax=10G MemorySwapMax=2G' in command[4]
    i = command.index('taskset')
    assert command[i+1:i+3] == ['-c', '0-9,12-31']
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    assert "localparam bit AO486_LINE_REPLAY = 1'b0;" in (root/'source/ao486-sim/ven/ven_ao486_shim.sv').read_text()
    (root/'defines.txt').write_text('\n'.join(sorted(defs))+'\n')
    dependency = parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dependency.read_text().replace('\\\n', ' ').split()[1:]:
        p = Path(name)
        if p.is_absolute(): pins[str(p)] = sha(p)
    for p in (*files, *(p for p in (root/'source').rglob('*') if p.is_file()), Path(__file__),
              Path(recipe.__file__), Path(base.__file__), Path(base.common.__file__), root/'defines.txt',
              parent/'build-started.json', parent/'build-closed.json', parent/'build.log', dependency,
              core/'build-started.json', core/'build-closed.json', core/'obj/tb_ventium'):
        pins[str(p)] = sha(p)
    assert stable(pins)
    save(root/'prepared.json', dict(command=command, pins=pins, changes=CHANGES, added_defines=[FLAG],
        parent=str(parent), directed_core=str(core), host=str(host), intersecting_rtl_sources=shared,
        parent_model=PARENT_MODEL, directed_model=CORE_MODEL, statistics=statistics,
        canonical_gate_passed=False, qualification='UNQUALIFIED', gameplay_ipc=None,
        inherited_fprem_repairs=True, included_fixes=['strict waiting-x87 #MF', 'DECODE no-beat bus payload']))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('prepare', 'build'))
    for n in ('parent', 'core', 'proof'): ap.add_argument('--'+n, type=Path)
    ap.add_argument('--out', type=Path, required=True)
    a = ap.parse_args()
    scratch, root = Path('/home/yukidama/external/tmp').resolve(strict=True), a.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and root != scratch
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3 and sha(base.__file__) == BUILDER
    if a.action == 'prepare':
        assert a.parent and a.core and a.proof
        prepare(a.parent.resolve(strict=True), a.core.resolve(strict=True), a.proof.resolve(strict=True), root)
        print('Prepared one HDL delta plus strict-MF define; no compiler launched.', flush=True)
        return 0
    return base.build(root)


if __name__ == '__main__':
    raise SystemExit(main())
