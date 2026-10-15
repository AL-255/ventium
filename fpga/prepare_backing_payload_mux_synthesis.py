"""Prepare matched, resource-guarded synthesis of the backing payload mux.

No timing, canonical or hardware pass is inherited. Preserve byte-identical
native ownership, watchdog, reaping and measured-growth disk admission code.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_backing_payload_mux_soc as native
import prepare_pair_next_disjoint_synthesis as prior
from prepare_fragment_exact_timing import replace, sha, span

ROOT, templates = prior.ROOT, prior.templates
MANIFEST = 'a14e64b46af3a14ca21400183c1e231ee2a80e335df59756426fa6f171494ab1'
MODEL = '917b5e3a729902f19410fdaa3b43ac9a8827612109013f04388f03556c95dd91'
AUDIT = '0930a519b3eed250b1a48b58f079cedfa659d222aa98ed558cfde441f6fbf5c1'

PROOF = '''funcproof=proof/'backing-payload-mux-freshfunc-r1/audit.json'
assert sha(funcproof)==''' + repr(AUDIT) + '''
func=load_proof('backing-payload-mux-freshfunc-r1/audit.json')
assert func['passed'] and func['fresh_qemu'] and func['qualified_private_reference']
assert func['functional_passes']==108 and func['functional_records']==80800
assert func['v_retirements']==30132 and func['unmasked_functional_passes']==105
assert not func['canonical_gate_passed'] and not func['hardware_acceptance']
assert func['model']==native.CORE_MODEL
pins.update(func['pins']);pins.update(func['artifacts'])
leaf=load_proof('backing-payload-mux-leaf-r1/closed.json')
assert leaf['passed'] and leaf['pins_unchanged'] and leaf['unfiltered_all_outputs']
assert len(leaf['rows'])==7 and sum(r['native_exit']==0 for r in leaf['rows'])==3
pins.update(leaf['pins'])
for row in leaf['rows']:pins.update(row['files'])
cache=load_proof('backing-payload-mux-cache-r2/closed.json')
assert cache['passed'] and cache['pins_unchanged'] and not cache['errors']
assert cache['contract_filter'] is None and cache['output_filter'] is None
assert [(r['label'],r['native_exit']) for r in cache['rows']]==[('positive',0),('late-address-negative',1)]
pins.update(cache['pins'])
for row in cache['native']:
    assert row['actual_wait'] and row['reaped'] and sha(row['log'])==row['sha256']
    pins[row['log']]=row['sha256']
system=load_proof('backing-payload-mux-system-r1/closed.json')
assert system['passed'] and system['pins_unchanged'] and len(system['rows'])==3
assert all(r['native_exit']==0 and r['actual_wait'] and r['reaped'] and r['affinity_verified'] for r in system['rows'])
for label,count in (('load',288),('store',288),('coldalias',144)):
    folder=proof/'backing-payload-mux-system-r1'/label
    checked=load_proof(str(folder.relative_to(proof)/'closed.json'))
    started=load_proof(str(folder.relative_to(proof)/'started.json'))
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert len(checked['measurements'])==count and started['models']['candidate']==str(core/'obj/tb_ventium')
    pins.update(started['pins'])
held=load_proof('backing-payload-mux-held-r1/result.json')
assert held['passed'] and held['inputs_unchanged'] and not held['errors'] and len(held['cases'])==48
pins.update(load_proof('backing-payload-mux-held-r1/inputs.json'))
verify=load_proof('backing-payload-mux-core-r1/verify-closed.json')
assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']
assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
assert len(verify['deltas'])==20 and all(r['same_records'] for r in verify['deltas'])
'''


def derive(original, changes):
    result = {}
    for name, text in prior.derive(original, changes).items():
        for old, new in (
            ('pair-next-disjoint-synthesis-r2', 'backing-payload-mux-synthesis-r1'),
            ('pair-next-disjoint-clock-r2', 'backing-payload-mux-clock-r1'),
            ('pair-next-disjoint-timing-prepared-r2.json', 'backing-payload-mux-timing-prepared-r1.json'),
            ('pair-next-disjoint-', 'backing-payload-mux-'),
            ('pair_next_disjoint_timing', 'backing_payload_mux_timing'),
            ('build_pair_next_disjoint_soc', 'build_backing_payload_mux_soc'),
            ('backing-payload-mux-synth-oct15-r2', 'backing-payload-mux-synth-oct15-r1'),
            ('backing-payload-mux-clock-oct15-r2', 'backing-payload-mux-clock-oct15-r1'),
            ('three-file pair/next arbitration transfer', 'one-file backing payload mux transfer'),
        ):
            name, text = name.replace(old, new), text.replace(old, new)
        if name.endswith('synthesis-r1/run.py'):
            text = span(text, 'funcproof=proof/', "pc=load_proof('backing-payload-mux-soc-r1/build-closed.json')", PROOF)
            text = replace(text, 'Measure checked pair/next arbitration exclusion; no route or deployment.',
                'Measure equivalent backing payload mux factoring; no route or deployment.')
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Separate address/strobe selection from unchanged late request admission. Exact one-file transform from retained 36.591166892 MHz parent, all-output four-state and real-L1 miters including idle hints, negative controls, fresh private-reference corpus, cold system cases and short cold-PC CRC/cycle checks. No feature/cache/latency/transport/clock change. Measure the mapped cone; source factoring alone establishes no timing gain. Canonical remains failed. No route, full-suite or physical acceptance inherited.',\n")
            text = replace(text,
                "generic_gate='FUNC 108/108 with existing masks; cycle/fault gates remain red; CPU lint only, not full SoC or suite'",
                "generic_gate='Fresh qualified-private-reference 108/108, 105 unmasked; canonical 7 PASS/101 FAIL, native exit 2; 20 cycle streams parent-identical, not band passes; CPU lint only, not full SoC or suite'")
            prior.guarded(text, original['prefix-payload-synthesis-r1/run.py'])
        if name.endswith('.py'):
            ast.parse(text, filename=name)
        result[name] = text
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    root = parser.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    source = root/'backing-payload-mux-fpga-r1'
    assert sha(source/'input-manifest.json') == MANIFEST
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256'] == prior.PARENT_MANIFEST
    assert sha(root/'backing-payload-mux-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    changes = {name:sha(source/name) for name in manifest['changed_parent_payloads']}
    assert set(changes) == {'ventium/'+n for n in native.CHANGES}
    for name in changes:
        assert native.transform(name.removeprefix('ventium/'), (root/'prefix-payload-fpga-r1'/name).read_text()) == (source/name).read_text()
    original, pins = {}, {}
    for name, digest in templates.TEMPLATES.items():
        path = root/name
        assert sha(path) == digest
        original[name] = path.read_text()
        pins[str(path)] = digest
    for module in (native, native.previous, native.recipe, prior, templates):
        path = Path(module.__file__).resolve()
        pins[str(path)] = sha(path)
    for path in (Path(__file__), native.original,
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py'),
                 Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(path.resolve())] = sha(path)
    outputs = derive(original, changes)
    receipt = root/'backing-payload-mux-timing-prepared-r1.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in outputs)
    for name, text in outputs.items():
        path = root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as stream:
            stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n):sha(root/n) for n in outputs},
            source_manifest_sha256=MANIFEST, model_sha256=MODEL, canonical_gate_passed=False,
            standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None), stream, indent=2)
    print('Guarded payload-mux controllers prepared; nothing launched.', flush=True)


if __name__ == '__main__':
    main()
