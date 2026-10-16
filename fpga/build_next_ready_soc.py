"""Transfer only the verified readiness cofactor into the boundary-stage PC.

Private diagnostic candidate: the canonical failure is retained. No timing,
standard-suite or hardware acceptance is inherited from an older source tree.
"""
import inspect
from pathlib import Path
import sys

import build_v_result_carry_soc as previous

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/l1'))
import build_next_ready_core as leaf
import prepare_next_ready_cofactor as recipe
from run_next_ready_func import MODEL as CORE_MODEL

base = previous.base
sha, load, save, stable = base.sha, base.load, base.save, base.stable
PARENT_MODEL = 'b32ab4b34482669c03ea57ce7be0dbd475623fa00b00c4c814fec976d75c86d2'
CHANGES = [recipe.FILE]
check_definitions = previous.check_definitions


def check_delta(name, before, after):
    if name == recipe.FILE:
        assert recipe.transform(before.decode()).encode() == after
        return True
    assert before == after, 'unreviewed source change: '+name
    return False


def evidence(proof, core):
    pins = {}
    for path in (core/'local-equivalence-audit.json', proof/'next-ready-func-r1/audit.json'):
        done = load(path)
        assert done['passed'] and done['model'] == CORE_MODEL
        assert not done['canonical_gate_passed'] and not done['standard_suite']
        assert not done['hardware_acceptance'] and done['gameplay_ipc'] is None
        pins.update(done['pins']); pins.update(done['artifacts']); pins[str(path)] = sha(path)
    local = load(core/'local-equivalence-audit.json')
    assert local['source_changes'] == CHANGES and local['symbolic_results'] == ['unsat','sat','sat','sat','sat']
    assert (local['leaf_samples'],local['cache_samples'],local['data_under_fill_cases']) == (983040,590084,640)
    assert (local['boundary_records'],local['boundary_v_retirements']) == (21832,4968)
    functional = load(proof/'next-ready-func-r1/audit.json')
    assert (functional['functional_passes'],functional['functional_records'],functional['v_retirements']) == (108,80800,30132)
    assert functional['unmasked_functional_passes'] == 105
    assert functional['unmasked_failures'] == ['tx_regform','tx_regform2','tx_stack']
    gate = load(core/'verify-closed.json')
    assert gate['canonical_gate_native_exit'] == 2 and not gate['canonical_gate_passed']
    assert gate['pins_unchanged'] and not gate['masks_or_goldens_or_bands_changed']
    assert len(gate['deltas']) == 20 and all(r['same_records'] for r in gate['deltas'])
    for name in ('load-store','integer'):
        root = proof/('next-ready-'+name+'-r1')
        start, done = load(root/'started.json'), load(root/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert start['pins'][str(core/'obj/tb_ventium')] == CORE_MODEL
        if name == 'load-store':
            assert len(done['measurements']) == 288 and done['memory_v_retirements'] == 456
            assert done['paired_by_shape'] == dict(zip(
                ('same-line','other-line','same-bank','alias','split','store-read'), (228,228,0,0,0,0)))
        else:
            assert len(done['measurements']) == 1024 and done['all_children_reaped']
            assert all(r['saved_clocks'] == 0 for r in done['deltas'])
        pins.update(start['pins'])
        for p in (root/'started.json',root/'closed.json'): pins[str(p)] = sha(p)
    for p in (core/'verify-started.json',core/'verify-closed.json',Path(previous.__file__)):
        pins[str(p)] = sha(p)
    assert stable(pins)
    return pins


def prepare_source():
    assert sha(previous.__file__) == '42cc3af8ab1d8ac7ca25f50d44c5e63a89ff5ac46705ba1c5c476b5597cee529'
    text = inspect.getsource(previous.prepare)
    for old, new in (
        ("assert old['directed_model']==leaf.MODEL and old['parent_profile']=='pipe-wait'",
         "assert old['directed_model']==leaf.MODEL and old['changes']==['rtl/core/core.sv','rtl/core/core_fetch_decode.svh']"),
        ("'sim_v_result_carry_'", "'sim_next_ready_'"),
        ('Path(recipe.__file__),Path(leaf.__file__),',
         'Path(recipe.__file__),Path(leaf.__file__),Path(previous.__file__),'),
        ('Only V arithmetic result loses carry input; original flag CF and all execution authority retained.',
         'Next-read readiness Boolean cofactor only; unchanged cycles and ownership. Canonical gate remains FAIL.'),
    ):
        assert text.count(old) == 1, old
        text = text.replace(old, new)
    return text


def main():
    scope = dict(previous.__dict__, __file__=__file__, previous=previous, leaf=leaf, recipe=recipe,
                 PARENT_MODEL=PARENT_MODEL, CORE_MODEL=CORE_MODEL, CHANGES=CHANGES,
                 evidence=evidence, check_delta=check_delta)
    exec(compile(prepare_source(), __file__, 'exec'), scope)
    exec(compile(inspect.getsource(previous.main), __file__, 'exec'), scope)
    return scope['main']()


if __name__ == '__main__': raise SystemExit(main())
