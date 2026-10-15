"""Prepare guarded 40 MHz measurements; preserve resource/lifetime controls.

Launches nothing. The candidate includes one HDL delta plus strict waiting-x87
policy; frequency differences cannot be attributed to the payload cut alone.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_decode_bus_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
DATA = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve(strict=True)
MANIFEST = '36908a9d96c4ddca51d143f634acacc85c067bfeb1aaf24833a9eda99fb6a7dc'
MODEL = '7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68'
PARENT_MANIFEST = 'f3d9952f0d85d60ce85a85bfec38bb37a939b39a739dc02e6ebde5a6d0297427'
PARENT_DCP = '0aaa3d5674f2adbaa99f5a1816a09b68f595cb347bd418ed3f6bb028c92036a6'
TEMPLATES = {
    'branch-address-synthesis-r1/run.py': 'b9d497b2ec26225b29368269ba4443135effc7cafd0911d3eac5dc2d02e7710e',
    'branch-address-synthesis-r1/audit_closed.py': 'b5f4286de5c467c370643ae11c7fc1adbefed8bcce285a06933df884b2f2237e',
    'branch-address-clock-r1/run.py': '38526b0b945838795c7783b78a4c23b96231d410d10362fe5c621f67e152d207',
    'branch-address-clock-r1/audit_closed.py': '8c6903e7ba815a0239e7f27ffb7651a6aa1c88b62db0e8b5bb1f1f70fa9ca2af',
    'branch-address-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
PROOF = '''# Source-linked local proof and current cold whole-core evidence.
for name in ('decode-bus-leaf-r1','decode-bus-boundary-r1','decode-bus-system-r1',
             'decode-bus-func-r1','decode-bus-delivery-r1'):
    checked=load_proof(name+'/closed.json')
    assert checked['pins_unchanged'] and not checked.get('errors')
    pins.update(load_proof(name+'/started.json')['pins'])
    if name=='decode-bus-delivery-r1':
        assert checked['completed'] and checked['candidate_passed'] and len(checked['rows'])==144
        assert all(r['passed'] and r['native']['actual_wait'] and r['native']['native_exit']==133 for r in checked['rows'])
    else:
        assert checked['passed']
    if name=='decode-bus-leaf-r1':
        assert len(checked['rows'])==5 and not checked['whole_core']
        assert [r['results']['proof']['answer'] for r in checked['rows']]==['unsat','sat','sat','sat','sat']
        pins.update(checked['artifacts'])
    if name=='decode-bus-boundary-r1':
        assert len(checked['rows'])==88 and checked['paired_v']>0 and checked['probe_witnesses']>0
    if name=='decode-bus-func-r1':
        assert len(checked['rows'])==108 and all(r['passed'] and r['actual_wait'] and
            r['affinity_verified'] and r['native_worker_exit']==0 for r in checked['rows'])
    if name=='decode-bus-system-r1':
        assert len(checked['rows'])==5 and all(r['passed'] and len(r['rows'])==6 for r in checked['rows'])
verify=load_proof('decode-bus-core-r1/verify-closed.json')
assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']
assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
assert len(verify['deltas'])==20 and all(r['same_records'] for r in verify['deltas'])
# Canonical failures remain failures. No standard-suite or physical pass.
'''


def common(text):
    return (text.replace('branch-address-', 'decode-bus-')
        .replace('branch_address_shape_timing', 'decode_bus_payload_timing')
        .replace('build_branch_address_soc', 'build_decode_bus_soc'))


def derive(original, changes):
    assert set(changes) == {'ventium/'+native.recipe.FILE}
    outputs = {}
    old = original['branch-address-synthesis-r1/run.py']
    text = common(old)
    text = replace(text, 'Measure early branch address plus three FPREM repairs; no route or deployment.',
        'Measure DECODE bus payload and strict x87 policy; no route or deployment.')
    text = replace(text, "len(manifest['hardware_defines']) == 158", "len(manifest['hardware_defines']) == 159")
    text = replace(text, "prepared['added_defines']==[]", "prepared['added_defines']==[native.FLAG]")
    text = replace(text, 'native.transform(name,before)', 'native.recipe.transform(before)')
    text = span(text, '# Current directed and FPU evidence;', "pc=load_proof('decode-bus-soc-r1/build-closed.json')", PROOF)
    text = span(text, '    rationale=', '    generic_gate=',
        "    rationale='Remove late overlength-probe qualification from the bus address in S_DECODE, a state with no bus request. Preserve MMU/fault/request authority and inherited FPREM repairs; add strict waiting-x87 exception policy. One RTL source plus one define. Source-linked local proof/mutants, cold boundary QEMU/A-B, 144 delayed-exception A-B executions, private functional/system controls, and exact short CoreMark clocks are required. Compare combined change against 35.814053435 MHz parent; no isolated timing gain, canonical waiver, route or board acceptance.',\n")
    guarded(text, old)
    a, b = 'host = available()\n', "(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)] == old[old.index(a):old.index(b)]
    outputs['decode-bus-synthesis-r1/run.py'] = text
    old = original['branch-address-clock-r1/run.py']
    text = common(old)
    text = replace(text, "len(manifest['hardware_defines']) == 158", "len(manifest['hardware_defines']) == 159")
    text = replace(text, str(DATA/'prefix-payload-synthesis-r1'), str(ROOT/'branch-address-synthesis-r1'))
    text = replace(text, '5c0ee4195b9331cf7eb31b022b86753feecd892cd3cff78cc1448c717b4b6557', PARENT_DCP)
    clock_guarded(text, old)
    outputs['decode-bus-clock-r1/run.py'] = text
    text = common(original['branch-address-synthesis-r1/audit_closed.py'])
    for suffix in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(DATA/('prefix-payload-'+suffix)), str(ROOT/('branch-address-'+suffix)))
    text = replace(text, '9e53127a928b0044465174583cb7ed87abc8da1d7644056054d3ceeeb5688bbb', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(changes)+'\n')
    text = replace(text, "assert manifest['hardware_defines'] == old_manifest['hardware_defines']",
        "assert manifest['hardware_defines'][155]=='VEN_X87_MF_STRICT'\n"
        "assert manifest['hardware_defines'][:155]+manifest['hardware_defines'][156:]==old_manifest['hardware_defines']")
    text = replace(text, "len(manifest['hardware_defines']) == 158", "len(manifest['hardware_defines']) == 159")
    text = replace(text, 'actual_defines=158', 'actual_defines=159')
    text = replace(text, 'only_added_define=None', "only_added_define='VEN_X87_MF_STRICT'")
    text = replace(text, 'four-file branch address and FPREM transfer', 'one-file DECODE bus transfer and strict waiting-x87 policy')
    text = replace(text, 'All feature definitions and clocks are unchanged;', 'Only strict waiting-x87 is added; clocks are unchanged;')
    outputs['decode-bus-synthesis-r1/audit_closed.py'] = text
    text = common(original['branch-address-clock-r1/audit_closed.py'])
    outputs['decode-bus-clock-r1/audit_closed.py'] = replace(text, '(-2.329)', '(-2.922)')
    outputs['decode-bus-clock-r1/audit.tcl'] = original['branch-address-clock-r1/audit.tcl']
    for name, text in outputs.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return outputs


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    source = root/'decode-bus-fpga-r1'
    assert sha(source/'input-manifest.json') == MANIFEST
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256'] == PARENT_MANIFEST and manifest['simulator_sha256'] == MODEL
    assert sha(root/'decode-bus-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    changes = {n: sha(source/n) for n in manifest['changed_parent_payloads']}
    for n in changes:
        assert native.recipe.transform((root/'branch-address-fpga-r1'/n).read_text()) == (source/n).read_text()
    original, pins = {}, {}
    for n, digest in TEMPLATES.items():
        p = root/n
        assert sha(p) == digest
        original[n], pins[str(p)] = p.read_text(), digest
    for p in (Path(__file__), Path(native.__file__), Path(native.recipe.__file__), Path(native.base.__file__),
              Path(__file__).with_name('prepare_fragment_exact_timing.py'),
              Path(__file__).with_name('prepare_payload_current_synthesis.py'),
              Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(p.resolve())] = sha(p)
    outputs = derive(original, changes)
    receipt = root/'decode-bus-timing-prepared.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in outputs)
    for n, text in outputs.items():
        p = root/n
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open('x') as f: f.write(text)
    with receipt.open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n): sha(root/n) for n in outputs},
            source_manifest_sha256=MANIFEST, model_sha256=MODEL, canonical_gate_passed=False,
            standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None), f, indent=2)
    print('Guarded synthesis/clock controllers prepared; neither launched.', flush=True)


if __name__ == '__main__':
    main()
