#!/usr/bin/env python3
"""Transfer the tested three-file SRT/V-clear derivative to the full PC.

The canonical failure remains a failure; this prepares a timing experiment,
not a standard-suite/FPGA-qualified release. Native build uses the unchanged
resource guard, private harness, warning comparison and header-dependency audit.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_payload_current_soc as base

REPO = base.REPO
sys.path.insert(0, str(REPO/'verif/srt'))
import build_rem_split_v_clear_core as recipe

sha, load, save, stable = base.sha, base.load, base.save, base.stable
PARENT_MODEL = '0910a3be8bf6c3a5d293dfd8204e0be89e98bb1163a4f2eb6e73f547ddff133a'
CORE_MODEL = '37250c5f8b7350d77b7e102e5fc6b7ebb99c078873534634e84f142c0b779329'


def regressions(core):
    root = core.parent
    pins, statistics = {}, {}
    for name, count in (('memory', 288), ('fp', 1536), ('integer', 1024), ('faults', 32)):
        folder = root/(name+'-r1')
        before, done = load(folder/'started.json'), load(folder/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert len(done['measurements']) == count and stable(before['pins'])
        assert before['models']['candidate'] == str(core/'obj/tb_ventium')
        if name == 'faults':
            assert all(not r[k]['timed_out'] and r[k]['native_exit'] == 0
                       for r in done['measurements'] for k in ('gate', 'complete_uv_compare'))
            assert all(sha(folder/p) == h for p,h in done['artifacts'].items())
        rows = [r for r in done['measurements'] if r['model'] == 'candidate']
        statistics[name] = dict(records=sum(r['records'] for r in rows), measurements=count)
        if name != 'faults':
            statistics[name]['paired_v'] = sum(r.get('paired_v', r.get('memory_v', 0)) for r in rows)
            assert statistics[name]['paired_v'] > 0
        pins.update(before['pins'])
        for p in (folder/'started.json', folder/'closed.json'): pins[str(p)] = sha(p)
    folder = root/'held-r1'
    done, inputs = load(folder/'result.json'), load(folder/'inputs.json')
    assert done['passed'] and done['inputs_unchanged'] and not done['errors']
    assert len(done['cases']) == 48 and str(core/'obj/tb_ventium') in inputs and stable(inputs)
    statistics['held'] = dict(records=sum(r['measurements']['candidate']['records'] for r in done['cases']))
    pins.update(inputs)
    replay = root/'canonical-r1'
    before, done = load(replay/'started.json'), load(replay/'closed.json')
    assert done['same_input_regression_passed'] and done['pins_unchanged'] and not done['errors']
    assert len(done['rows']) == 108 and done['records'] == 80800 and stable(before['pins'])
    assert before['models']['candidate'] == str(core/'obj/tb_ventium')
    pins.update(before['pins'])
    for p in (folder/'result.json', folder/'inputs.json', replay/'started.json', replay/'closed.json'):
        pins[str(p)] = sha(p)
    return pins, statistics


def prepare(parent, core, root):
    assert not root.exists()
    old, done = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert done['passed'] and done['inputs_unchanged'] and done['native_exit'] == 0
    assert done['binary_sha256'] == sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == PARENT_MODEL
    started, built = load(core/'build-started.json'), load(core/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0
    assert built['binary_sha256'] == sha(core/'obj/tb_ventium') == CORE_MODEL and stable(started['pins'])
    assert started['changes'] == recipe.TARGETS
    pins, statistics = regressions(core)
    source = parent/'source'
    files = sorted(p for p in source.rglob('*') if p.is_file())
    assert all(not p.is_symlink() and sha(p) == old['pins'][str(p)] for p in files)
    changed = recipe.srt.transform({n: (source/n).read_text() for n in recipe.srt.HASHES})
    changed['rtl/core/core.sv'] = recipe.clear.transform((source/'rtl/core/core.sv').read_text())
    assert all(text == (core/'candidate'/n).read_text() for n,text in changed.items())
    shared = [str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl','fp_shared')
              and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared) == 102
    assert [n for n in shared if sha(source/n) != sha(core/'candidate'/n)] == recipe.TARGETS
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts) == 1
    root.mkdir(); shutil.copytree(source, root/'source')
    for name in recipe.TARGETS: shutil.copyfile(core/'candidate'/name, root/'source'/name)
    assert all(sha(root/'source'/n) == sha(core/'candidate'/n) for n in shared)
    host = root/'source/ao486-sim/ven'/('sim_rem_split_'+hashlib.sha256(str(root).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0], host)
    command = [s.replace(str(parent), str(root)) for s in old['command']]
    command = [str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    defs = [s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs) == len(set(defs)) == 155 and recipe.srt.FLAG not in defs
    assert {'VEN_FE_PIPE','VEN_SYS_FASTPATH_RELOC','VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_P54_DUAL_LOAD_PAIR'} <= set(defs)
    command.insert(command.index('/tools/verilator/v5.046/bin/verilator')+1, '+define+'+recipe.srt.FLAG)
    defs.append(recipe.srt.FLAG)
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (root/'defines.txt').write_text('\n'.join(sorted(defs))+'\n')
    dep = parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dep.read_text().replace('\\\n',' ').split()[1:]:
        path = Path(name)
        if path.is_absolute(): pins[str(path)] = sha(path)
    for p in (*files, *(p for p in (root/'source').rglob('*') if p.is_file()), Path(__file__), Path(base.__file__),
              Path(recipe.__file__), Path(recipe.srt.__file__), Path(recipe.clear.__file__), root/'defines.txt',
              parent/'build-started.json', parent/'build-closed.json', parent/'build.log',
              core/'build-started.json', core/'build-closed.json', core/'obj/tb_ventium'):
        pins[str(p)] = sha(p)
    assert stable(pins)
    save(root/'prepared.json', dict(command=command, pins=pins, changes=recipe.TARGETS,
        added_defines=[recipe.srt.FLAG], parent=str(parent), directed_core=str(core),
        host=str(host), intersecting_rtl_sources=shared, statistics=statistics,
        parent_model=PARENT_MODEL, directed_model=CORE_MODEL,
        canonical_gate_passed=False, qualification='UNQUALIFIED'))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('prepare','build'))
    for name in ('parent','core'): ap.add_argument('--'+name, type=Path)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch, root = Path('/home/yukidama/external/tmp').resolve(strict=True), args.out.resolve()
    assert __debug__ and root.is_relative_to(scratch) and root != scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        prepare(args.parent.resolve(strict=True), args.core.resolve(strict=True), root)
        print('Prepared matched SRT/V-clear PC; no compiler launched.', flush=True)
    else:
        raise SystemExit(base.build(root))
