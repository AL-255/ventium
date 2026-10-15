"""Transfer the checked single-file backing payload mux to the frozen PC.

Require fresh private-reference comparisons, canonical failure disclosure and
cold load/store/translation checks. Preserve the native compiler lifecycle,
102-source transfer audit, 156 definitions and single-fill/posted16 transport.
"""
import ast
from pathlib import Path
import sys

import build_fetch_fragment_soc as previous

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO/'verif/l1'))
import prepare_backing_payload_mux as recipe

tooling = previous.tooling


def transform(name, source):
    if name != 'rtl/mem/ven_l1d.sv':
        raise ValueError('unreviewed source delta: '+name)
    return recipe.transform(source)


def once(text, before, after):
    assert text.count(before) == 1, before
    return text.replace(before, after, 1)


def derive():
    original, text = previous.derive()
    for before, after in (
        ('CHANGES = [recipe.FILE]', "CHANGES = ['rtl/mem/ven_l1d.sv']"),
        (tooling.MODEL, '7c88579767354f269055420cafe3acca089acda87e5ac174b633b3e7905dcdb5'),
        ("proof / 'fetch-fragment-core-r1'", "proof / 'backing-payload-mux-core-r1'"),
        ('fetch-fragment-regression-audit.json', 'backing-payload-mux-freshfunc-r1/audit.json'),
        ('sim_fetch_fragment_', 'sim_backing_payload_mux_'),
        ('tooling_deltas = tooling.qualify_tooling(pins)',
         'tooling_deltas = {}  # Current closure; no inherited tool-pin migration.'),
        ('original, Path(recipe.__file__), Path(tooling.__file__),',
         'original, Path(previous.__file__), Path(recipe.__file__), Path(tooling.__file__),'),
    ):
        text = once(text, before, after)
    begin = text.index("    assert audit['audit_passed']")
    end = text.index('    before, built =', begin)
    text = text[:begin] + '''    assert audit['passed'] and audit['fresh_qemu'] and audit['qualified_private_reference']
    assert (audit['functional_passes'], audit['functional_records'], audit['v_retirements']) == (108,80800,30132)
    assert audit['unmasked_functional_passes'] == 105 and not audit['canonical_gate_passed']
    assert audit['model'] == CORE_MODEL and not audit['standard_suite'] and not audit['hardware_acceptance']
    pins = dict(audit['pins'])
    pins.update(audit['artifacts'])
    gate = load(core/'verify-closed.json')
    assert gate['canonical_gate_native_exit'] == 2 and not gate['canonical_gate_passed']
    assert gate['pins_unchanged'] and not gate['masks_or_goldens_or_bands_changed']
    assert len(gate['deltas']) == 20 and all(r['same_records'] for r in gate['deltas'])
    assert 'func totals: 7 PASS / 101 FAIL / 108 total' in (core/'generic.log').read_text()
    directed = proof/'backing-payload-mux-system-r1'
    started, checked = load(directed/'started.json'), load(directed/'closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and len(checked['rows']) == 3
    assert all(r['native_exit'] == 0 and r['actual_wait'] and r['reaped'] and r['affinity_verified']
               for r in checked['rows'])
    pins.update(started['pins'])
    for label,count,paired in (('load',288,1500),('store',288,456),('coldalias',144,581)):
        leaf = directed/label
        status = load(leaf/'closed.json')
        origin = load(leaf/'started.json')
        assert status['passed'] and status['pins_unchanged'] and not status['errors']
        assert len(status['measurements']) == count and status['memory_v_retirements'] == paired
        assert origin['models']['candidate'] == str(core/'obj/tb_ventium')
        pins.update(origin['pins'])
    pins.update(load((directed/'coldalias').with_suffix('.inputs.json')))
    held = proof/'backing-payload-mux-held-r1'
    checked = load(held/'result.json')
    assert checked['passed'] and checked['inputs_unchanged'] and not checked['errors']
    assert len(checked['cases']) == 48
    inputs = load(held/'inputs.json')
    assert str(core/'obj/tb_ventium') in inputs
    pins.update(inputs)
    for folder in (directed, held):
        for p in folder.rglob('*'):
            if p.is_file(): pins[str(p)] = sha(p)
''' + text[end:]
    ast.parse(text)
    return original, text


original, derived = derive()
exec(compile(derived, str(__file__), 'exec'), globals())
