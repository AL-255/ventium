"""Transfer the boundary-only fetch stage for diagnostic full-PC cost tests.

This is NOT canonical/standard-suite acceptance. The original make-verify and
cycle-equivalence failure remain recorded. A separate, explicit diagnostic
policy permits measuring the already observed +21-clock branch fixture while
requiring all retirement identities/pair decisions and the other 19 streams.
"""
import argparse
import inspect
import os
from pathlib import Path
import shutil
import sys

import build_v_result_carry_soc as previous

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/fe_pipe'))
sys.path.insert(0, str(REPO/'verif/diff'))
import build_sfetch_beat_core as leaf
import prepare_sfetch_boundary_stage as recipe
import tracefmt

base = previous.base
sha, load, save, stable = base.sha, base.load, base.save, base.stable
PARENT_MODEL = 'b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e'
CORE_MODEL = 'e604895eeb367591b16a564d4b91b282a30a6c65b3bee5c7f81823c5e48ae56a'
CHANGES = sorted(recipe.PARENTS)
PREPARE_SHA = '42cc3af8ab1d8ac7ca25f50d44c5e63a89ff5ac46705ba1c5c476b5597cee529'
BUILD_SHA = '9951c6768f0441d63a0dec66ad6b302afb019924fce529c9d034b1e41c01c8a3'


def check_cycle_records(name, old, new):
    """Check measured cost, never redefine the original equivalence result."""
    assert len(old) == len(new) > 0
    if name != 'mb_brrandom.cycle_rtl.vtrace':
        assert old == new, ('unexpected cycle change', name)
        return dict(name=name, records=len(new), added_clocks=0)
    assert len(old) == 4603
    assert old[-1]['cyc'] == 30125 and new[-1]['cyc'] == 30146
    differences = []
    for a, b in zip(old, new):
        assert {k:v for k,v in a.items() if k != 'cyc'} == {k:v for k,v in b.items() if k != 'cyc'}
        differences.append(b['cyc'] - a['cyc'])
    assert differences[0] == 0 and differences[-1] == 21
    assert all(0 <= x <= y <= 21 for x,y in zip(differences, differences[1:]))
    return dict(name=name, records=len(new), added_clocks=21)


def cycle_cost_diagnostic(core):
    gate = load(core/'verify-closed.json')
    assert gate['canonical_gate_native_exit'] == 2 and not gate['canonical_gate_passed']
    assert gate['pins_unchanged'] and not gate['masks_or_goldens_or_bands_changed']
    assert len(gate['deltas']) == 20
    assert [r['name'] for r in gate['deltas'] if not r['same_records']] == ['mb_brrandom.cycle_rtl.vtrace']
    start = load(core/'verify-started.json')
    assert stable(start['pins'])
    parent = Path(load(core/'build-started.json')['parent'])
    old = sorted((parent/'generic-work').glob('*.cycle_rtl.vtrace'))
    new = sorted((core/'generic-work').glob('*.cycle_rtl.vtrace'))
    assert len(old) == len(new) == 20 and [p.name for p in old] == [p.name for p in new]
    pins = dict(start['pins'])
    rows = []
    for a,b in zip(old,new):
        rows.append(check_cycle_records(b.name, tracefmt.read_trace(str(a)).records,
                                       tracefmt.read_trace(str(b)).records))
        for p in (a,b): pins[str(p)] = sha(p)
    for p in (core/'verify-started.json', core/'verify-closed.json', Path(tracefmt.__file__)):
        pins[str(p)] = sha(p)
    return pins, dict(canonical_gate_passed=False, cycle_equivalence_passed=False,
                      diagnostic_only=True, measured_cycle_costs=rows)


def evidence(proof, core):
    pins, _ = cycle_cost_diagnostic(core)
    for profile in ('default', 'interior'):
        root = proof/('sfetch-boundary-leaf-'+profile+'-r1')
        start, done = load(root/'started.json'), load(root/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert [(r['mode'],r['native_exit']) for r in done['rows']] == [
            ('positive',0), ('bypass',1), ('lose-walk',1), ('raw-ack',1), ('reload',1), ('wrong-size',1)]
        assert all(r['compile_exit']==0 and r['actual_wait'] and r['passed'] for r in done['rows'])
        pins.update(start['pins']); pins.update(done['artifacts'])
        for p in (root/'started.json',root/'closed.json'): pins[str(p)] = sha(p)
    for name,key,count in (('boundaries','rows',88), ('demand','measurements',192), ('finite-cs','rows',8)):
        root = proof/('sfetch-boundary-'+name+'-r1')
        start,done = load(root/'started.json'),load(root/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert len(done[key])==count and start['pins'][str(core/'obj/tb_ventium')]==CORE_MODEL
        if name=='boundaries': assert done['candidate_records']==21832 and done['paired_v']==4968
        if name=='demand': assert done['clean_resources'] and done['all_children_reaped']
        if name=='finite-cs': assert not done['qemu_differential'] and not done['original_gate_passed']
        pins.update(start['pins'])
        for p in (root/'started.json',root/'closed.json'): pins[str(p)] = sha(p)
    root = proof/'sfetch-boundary-func-r1'
    audited = load(root/'audit.json')
    assert audited['passed'] and audited['model']==CORE_MODEL
    assert audited['functional_passes']==108 and audited['functional_records']==80800
    assert audited['v_retirements']==30132 and audited['unmasked_functional_passes']==105
    assert not audited['canonical_gate_passed'] and not audited['standard_suite']
    pins.update(audited['pins']); pins.update(audited['artifacts'])
    pins[str(root/'audit.json')] = sha(root/'audit.json')
    assert stable(pins)
    return pins


def prepare_source():
    assert sha(previous.__file__) == PREPARE_SHA
    text = inspect.getsource(previous.prepare)
    for old,new in (
        ("assert old['directed_model']==leaf.MODEL and old['parent_profile']=='pipe-wait'",
         "assert old['directed_model']==leaf.MODEL and old['changes']==previous.CHANGES"),
        ("'sim_v_result_carry_'", "'sim_sfetch_boundary_'"),
        ('Path(recipe.__file__),Path(leaf.__file__),',
         'Path(recipe.__file__),Path(recipe.base.__file__),Path(previous.__file__),Path(leaf.__file__),'),
        ('Only V arithmetic result loses carry input; original flag CF and all execution authority retained.',
         'Boundary-only fetch stage. DIAGNOSTIC cost experiment; canonical and cycle-equivalence gates remain FAIL.'),
        ('gameplay_ipc=None,', 'gameplay_ipc=None,cycle_cost=cycle_cost_diagnostic(core)[1],'),
    ):
        text = recipe.replace_once(text,old,new)
    return text


def prepare(parent, core, proof, root):
    namespace = dict(previous.__dict__, __file__=__file__, previous=previous, leaf=leaf,
                     recipe=recipe, PARENT_MODEL=PARENT_MODEL, CORE_MODEL=CORE_MODEL,
                     CHANGES=CHANGES, evidence=evidence, cycle_cost_diagnostic=cycle_cost_diagnostic)
    # check_delta must see the new exact two-file recipe, not its old globals.
    exec(compile(inspect.getsource(previous.check_delta),__file__,'exec'),namespace)
    exec(compile(prepare_source(),__file__,'exec'),namespace)
    namespace['prepare'](parent,core,proof,root)


def build_source():
    assert sha(base.__file__) == BUILD_SHA
    text = inspect.getsource(base.build)
    return recipe.replace_once(text,
        "assert len(checked['deltas']) == 20 and all(r['same_records'] for r in checked['deltas'])",
        "assert before['cycle_cost'] == cycle_cost_diagnostic(Path(before['directed_core']))[1]\n"
        "    assert not checked['canonical_gate_passed']")


def build(root):
    namespace = dict(base.__dict__, __file__=__file__, cycle_cost_diagnostic=cycle_cost_diagnostic)
    exec(compile(build_source(),__file__,'exec'),namespace)
    return namespace['build'](root)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    for name in ('parent','core','proof'): ap.add_argument('--'+name,type=Path)
    ap.add_argument('--out',type=Path,required=True)
    a = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = a.out.resolve()
    assert __debug__ and root!=scratch and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert shutil.disk_usage(scratch).free > 5*1024**3
    if a.action=='prepare':
        prepare(a.parent.resolve(strict=True),a.core.resolve(strict=True),a.proof.resolve(strict=True),root)
        print('Prepared diagnostic full-PC stage transfer; canonical FAIL retained.',flush=True)
        return 0
    return build(root)


if __name__=='__main__': raise SystemExit(main())
