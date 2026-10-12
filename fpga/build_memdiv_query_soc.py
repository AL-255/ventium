"""Transfer the checked query selector to the exact memory-divide PC parent.

This is admission to a timing experiment, not a canonical/full-suite/FPGA pass.
All 102 shared RTL inputs, 156 definitions and posted-16 transport are checked.
The existing native builder retains its bounded 32-job scope and header audit.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sys

import build_payload_current_soc as base
REPO = base.REPO
sys.path.insert(0, str(REPO/'verif/l1'))
import prepare_prime_query_payload as recipe

sha, load, save, stable = base.sha, base.load, base.save, base.stable
PARENT_MODEL = '10d875b4cf1680d50906434ee3d5572ce1ee0f8175a792c8a7554d8728c6f3fe'
CORE_MODEL = 'e65a06e1e3c26d48723bdeb0d9d97061879f15b1ff916e493d4fe94ae336a525'


def regressions(core):
    root, pins, statistics = core.parent, {}, {}
    model = str(core/'obj/tb_ventium')
    for label, count in (('fp', 1536), ('memory', 288), ('branch', 2560), ('faults', 32)):
        folder = root/('memdiv-query-'+label+'-r1')
        before, done = load(folder/'started.json'), load(folder/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert before['models']['candidate'] == model and stable(before['pins'])
        assert len(done['measurements']) == count
        rows = [r for r in done['measurements'] if r['model'] == 'candidate']
        assert len(rows) == count//2
        if label == 'faults':
            assert all(not r[k]['timed_out'] and r[k]['native_exit'] == 0
                       for r in done['measurements'] for k in ('gate', 'complete_uv_compare'))
            assert all(sha(folder/p) == h for p, h in done['artifacts'].items())
        elif label == 'fp':
            assert len(done['deltas']) == count//2
            assert all(r['saved_clocks'] == 0 for r in done['deltas'])
        else:
            assert sum(r.get('paired_v', r.get('memory_v', 0)) for r in rows) > 0
        statistics[label] = dict(records=sum(r['records'] for r in rows), measurements=count)
        pins.update(before['pins'])
        for p in (folder/'started.json', folder/'closed.json'): pins[str(p)] = sha(p)
    folder = root/'memdiv-query-held-r1'
    done, inputs = load(folder/'result.json'), load(folder/'inputs.json')
    assert done['passed'] and done['inputs_unchanged'] and not done['errors']
    assert len(done['cases']) == 48 and model in inputs and stable(inputs)
    assert all(r['measurements']['control'] == r['measurements']['candidate'] for r in done['cases'])
    statistics['held'] = dict(records=sum(r['measurements']['candidate']['records'] for r in done['cases']))
    pins.update(inputs)
    for p in (folder/'result.json', folder/'inputs.json'): pins[str(p)] = sha(p)
    for label in ('agi', 'ref'):
        folder = root/('memdiv-query-'+label+'-r1')
        before, done = load(folder/'started.json'), load(folder/'closed.json')
        assert done['passed'] and done['native_exit'] == 0 and done['pins_unchanged']
        assert done['fixture_cases'] == 20 and not done['errors'] and stable(before['pins'])
        assert before['command'][before['command'].index('--candidate')+1] == model
        matrix = load(folder/'matrix/result.json')
        inputs = load(folder/'matrix/inputs.json')
        assert matrix['passed'] and matrix['inputs_unchanged'] and not matrix['errors']
        assert len(matrix['measurements']) == 80 and model in inputs and stable(inputs)
        rows = {(tuple(r['case']), r['model'], r['latency']): r for r in matrix['measurements']}
        for (case, who, latency), a in rows.items():
            if who != 'control': continue
            b = rows[case, 'candidate', latency]
            for key in ('state_sha256', 'cycle_sha256', 'resident_primes', 'total_clocks', 'warm_cycles'):
                assert a[key] == b[key], (label, case, latency, key)
        assert done['paired_v'] > 0 and done['candidate_primes'] > 0
        statistics[label] = dict(records=done['candidate_records'], primes=done['candidate_primes'])
        pins.update(before['pins']); pins.update(inputs)
        for p in (folder/'started.json', folder/'closed.json', folder/'matrix/result.json', folder/'matrix/inputs.json'):
            pins[str(p)] = sha(p)
    folder = root/'memdiv-query-replay-r1'
    before, done = load(folder/'started.json'), load(folder/'closed.json')
    assert done['same_input_regression_passed'] and done['pins_unchanged'] and not done['errors']
    assert len(done['rows']) == 108 and done['records'] == 80800 and stable(before['pins'])
    assert before['models']['candidate'] == model
    pins.update(before['pins'])
    for p in (folder/'started.json', folder/'closed.json'): pins[str(p)] = sha(p)
    # Full QEMU and A/B re-comparison preceded each lossless compaction.
    for name, records in (('closed-memdiv-query-fp-text', 208128),
                          ('closed-memdiv-query-memory-text', 385312)):
        done = load(root/(name+'-closed.json'))
        assert done['completed'] and done['all_members_byte_verified'] and done['protected_pins_unchanged']
        assert sum(r['candidate_records'] for r in done['statistics']) == records
        assert sha(root/(name+'.tar.gz')) == done['archive_sha256']
        for suffix in ('-closed.json', '-plan.json', '.tar.gz'):
            p = root/(name+suffix); pins[str(p)] = sha(p)
    return pins, statistics


def prepare(parent, core, out):
    assert not out.exists()
    old, closed = load(parent/'build-started.json'), load(parent/'build-closed.json')
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit'] == 0
    assert closed['binary_sha256'] == sha(parent/'obj1-speed-q16-parentpolicy/ao486sim_board_posted') == PARENT_MODEL
    started, built = load(core/'build-started.json'), load(core/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit'] == 0 and stable(started['pins'])
    assert built['binary_sha256'] == sha(core/'obj/tb_ventium') == CORE_MODEL
    assert started['changes'] == [recipe.PAYLOAD]
    pins, statistics = regressions(core)
    source = parent/'source'
    files = sorted(p for p in source.rglob('*') if p.is_file())
    assert all(not p.is_symlink() and sha(p) == old['pins'][str(p)] for p in files)
    assert recipe.transform((source/recipe.PAYLOAD).read_text()) == (core/'candidate'/recipe.PAYLOAD).read_text()
    shared = [str(p.relative_to(source)) for p in files if p.relative_to(source).parts[0] in ('rtl', 'fp_shared')
              and (core/'candidate'/p.relative_to(source)).is_file()]
    assert len(shared) == 102
    assert [n for n in shared if sha(source/n) != sha(core/'candidate'/n)] == [recipe.PAYLOAD]
    hosts = [Path(s) for s in old['command'] if s.startswith(str(source/'ao486-sim/ven/sim_')) and s.endswith('.cpp')]
    assert len(hosts) == 1
    out.mkdir(); shutil.copytree(source, out/'source')
    shutil.copyfile(core/'candidate'/recipe.PAYLOAD, out/'source'/recipe.PAYLOAD)
    assert all(sha(out/'source'/n) == sha(core/'candidate'/n) for n in shared)
    host = out/'source/ao486-sim/ven'/('sim_memdiv_query_'+hashlib.sha256(str(out).encode()).hexdigest()[:12]+'.cpp')
    shutil.copyfile(hosts[0], host)
    command = [s.replace(str(parent), str(out)) for s in old['command']]
    command = [str(host) if s.endswith('/'+hosts[0].name) else s for s in command]
    definitions = [s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(definitions) == len(set(definitions)) == 156
    assert set(definitions) == set((parent/'defines.txt').read_text().splitlines())
    assert '-GBOARD_POSTED=1' in command and '-GBOARD_WRITE_SLOTS=16' in command
    (out/'defines.txt').write_text('\n'.join(sorted(definitions))+'\n')
    dependency = parent/'obj1-speed-q16-parentpolicy'/(hosts[0].stem+'.d')
    for name in dependency.read_text().replace('\\\n', ' ').split()[1:]:
        p = Path(name)
        if p.is_absolute(): pins[str(p)] = sha(p)
    for p in (*files, *(p for p in (out/'source').rglob('*') if p.is_file()), Path(__file__),
              Path(recipe.__file__), Path(base.__file__), Path(base.common.__file__), out/'defines.txt',
              parent/'build-started.json', parent/'build-closed.json', parent/'build.log',
              core/'build-started.json', core/'build-closed.json', core/'obj/tb_ventium'):
        pins[str(p)] = sha(p)
    assert stable(pins)
    save(out/'prepared.json', dict(command=command, pins=pins, changes=[recipe.PAYLOAD], added_defines=[],
        parent=str(parent), directed_core=str(core), host=str(host), intersecting_rtl_sources=shared,
        statistics=statistics, parent_model=PARENT_MODEL, directed_model=CORE_MODEL,
        canonical_gate_passed=False, qualification='UNQUALIFIED'))


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('prepare', 'build'))
    for name in ('parent', 'core'): ap.add_argument('--'+name, type=Path)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True); out = args.out.resolve()
    assert __debug__ and out.is_relative_to(scratch) and out != scratch
    assert Path(os.environ['TMPDIR']).resolve() == scratch and scratch.stat().st_dev != REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if args.action == 'prepare':
        prepare(args.parent.resolve(strict=True), args.core.resolve(strict=True), out)
        print('Prepared query-selector PC transfer; compiler not launched.', flush=True)
    else: raise SystemExit(base.build(out))
