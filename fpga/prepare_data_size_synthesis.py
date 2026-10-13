"""Prepare matched synthesis of the one-file data-size cut; launch nothing.

Retain the closed general-repair parent's resource admission and lifecycle.
Only exact source/proof identities and the matched timing parent change.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_data_size_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

SCRATCH = Path('/home/yukidama/external/tmp').resolve(strict=True)
PARENT = SCRATCH / 'ventium-fp-repair-transfer.a8nzrjHu'
OLDER = SCRATCH / 'ventium-load-read-ack.GyWDDtiI'
MANIFEST = '8e8ab037834da5120453149a60766b4455f60be0e14e06f6a7be33a19aa5b864'
MODEL = 'c0de36c5456d737ed38431598095f3df7d5c03f4f61da5e9462d1ddb23cd772f'
PARENT_MANIFEST = 'bf2a944dc6aedaa7ec406fdf5c5607c54d707b8cb04fa25ad88b6ba74fac9b93'
PARENT_DCP = 'd801ced570e78057204df123ad72a899b0dc2ed6ed5e22490efdaa0ce61d1b97'
CHANGES = {'ventium/rtl/core/core.sv': '6c020b3c171fb422756a7874fb48cd32a683953ff5b95d44b708be3a7fa08b1c'}
TEMPLATES = {
    'synthesis-r1/run.py': '5465b056711c96458b3c302cc36f0545020282ac7a5e2a2c6ba6d5b350dbd09d',
    'synthesis-r1/audit_closed.py': '657af5bdf84ef04a03da3e6e820aa7071261d84ddaa88e8bf775ab1341e24676',
    'clock-r1/run.py': '288bf37e9572c85555430b0aa04a5ed4b1f27829d07b8de7b8e382854dd63975',
    'clock-r1/audit_closed.py': '3cdf0f7e08cb43f19763c11e5a044cf2f7da7b4f29283bd3dceeba38f224d2f5',
    'clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
PROOF = '''import sys
sys.path.insert(0,str(repo/'fpga'))
import build_data_size_soc as native
prepared=load_proof('soc-r1/prepared.json')
assert len(prepared['intersecting_rtl_sources'])==102 and prepared['changes']==native.CHANGES
assert prepared['added_defines']==[] and prepared['directed_model']==native.CORE_MODEL
assert prepared['parent_model']==native.PARENT_MODEL and prepared['functional_corpus_passed']
assert not prepared['canonical_gate_passed'] and prepared['qualification']=='UNQUALIFIED'
pins.update(prepared['pins'])
core=Path(prepared['directed_core'])
for name in prepared['intersecting_rtl_sources']:
    assert sha(proof/'soc-r1/source'/name)==sha(core/'candidate'/name)
for name in prepared['changes']:
    before=(Path(prepared['parent'])/'source'/name).read_text()
    assert native.recipe.transform(before)==(proof/'soc-r1/source'/name).read_text()
funcproof=proof/'audit.json'
assert sha(funcproof)==native.AUDIT
func=json.loads(funcproof.read_text())
assert func['audit_passed'] and func['functional_passes']==108 and func['functional_records']==80800
assert func['v_retirements']==30134 and func['unmasked_functional_passes']==105
assert func['fetch_boundary_cases']==22 and func['cycle_traces_unchanged']==20
assert not func['canonical_gate_passed'] and not func['hardware_acceptance']
pins.update(func['artifacts']); pins[str(funcproof)]=sha(funcproof)
pc=load_proof('soc-r1/build-closed.json')
assert pc['passed'] and pc['native_exit']==0 and pc['inputs_unchanged'] and not pc['errors']
assert pc['binary_sha256']==model and pc['structural_warnings_unchanged'] and pc['structural_debt_count']==98
timing=load_proof('timing-prepared.json')
assert timing['unchanged_guard_lifecycle'] and timing['controllers_generated_not_launched']
assert timing['source_manifest_sha256']==manifest_sha and timing['model_sha256']==model
pins.update(timing['template_pins']); pins.update(timing['outputs'])
assert all(sha(p)==h for p,h in pins.items())
'''


def derive(original):
    result = {}
    for phase in ('synthesis', 'clock'):
        old = original[phase + '-r1/run.py']
        text = old.replace('ventium-fp-repair-', 'ventium-data-size-')
        text = replace(text, "manifest['variant'] == 'fp_general_repairs_timing'", "manifest['variant'] == 'data_size_timing'")
        if phase == 'synthesis':
            text = span(text, 'import sys\nsys.path.insert', "cmroot=root.parent/'soc-r1/coremark'", PROOF)
            text = replace(text, 'Measure the source-matched general ISA/x87 repairs and segment-extent rewrite; no route or deployment.',
                           'Measure the source-matched data-size cofactor; no route or deployment.')
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Remove fetch-demand sizing from the inactive data-segment extent consumer only. The matched general-repair parent estimates 35.856430851 MHz. Exactly one RTL file changes; same 158 hardware defines, UV-fast/full P5 caches, posted-16 transport, logic-only mapper and 40/100 MHz constraints. No pipeline stage, timing exception or guest workaround. Functional corpus and short CoreMark pass; canonical, full suite and physical acceptance remain open.',\n")
            guarded(text, old)
        else:
            text = replace(text, str(OLDER/'endpoint-map-synthesis-r1'), str(PARENT/'synthesis-r1'))
            text = replace(text, 'b84da6e30f8b87f26bcc86f03d23a8df44644fb272af8713316d3472721d2d12', PARENT_DCP)
            clock_guarded(text, old)
        result[phase + '-r1/run.py'] = text
    text = original['synthesis-r1/audit_closed.py']
    for suffix in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(OLDER/('endpoint-map-'+suffix)), str(PARENT/suffix))
    text = replace(text, 'ventium-fp-repair-synth-oct13.service', 'ventium-data-size-synth-oct13.service')
    text = replace(text, 'c45c29a6b2ae32fdd34defe85a6922e8560b2ccb9054b5d1563ae773a9040bd1', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    result['synthesis-r1/audit_closed.py'] = replace(text, 'eight-file general repair transfer', 'one-file data-size transfer')
    text = original['clock-r1/audit_closed.py']
    text = replace(text, 'ventium-fp-repair-clock-oct13.service', 'ventium-data-size-clock-oct13.service')
    result['clock-r1/audit_closed.py'] = replace(text, '(-3.525)', '(-2.889)')
    result['clock-r1/audit.tcl'] = original['clock-r1/audit.tcl']
    for name, text in result.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root == SCRATCH/'ventium-data-size.v2HaTO2X'
    assert Path(os.environ['TMPDIR']).resolve() == SCRATCH
    source = root/'fpga-r1'
    assert sha(source/'input-manifest.json') == MANIFEST
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    assert set(manifest['changed_parent_payloads']) == set(CHANGES)
    assert sha(root/'soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    for name, digest in CHANGES.items():
        assert sha(source/name) == digest
        assert native.recipe.transform((PARENT/'fpga-r1'/name).read_text()) == (source/name).read_text()
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        path = PARENT/name
        assert sha(path) == digest
        original[name] = path.read_text(); pins[str(path)] = digest
    for path in (Path(__file__), Path(native.__file__), Path(native.recipe.__file__),
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py'),
                 Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(path.resolve())] = sha(path)
    outputs = derive(original)
    assert not (root/'timing-prepared.json').exists()
    assert all(not (root/name).exists() for name in outputs)
    for name, text in outputs.items():
        path = root/name; path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as f: f.write(text)
    with (root/'timing-prepared.json').open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n):sha(root/n) for n in outputs},
            source_manifest_sha256=MANIFEST, model_sha256=MODEL, canonical_gate_passed=False,
            standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None), f, indent=2)
    print('Prepared guarded data-size synthesis/timing; nothing launched.', flush=True)


if __name__ == '__main__': main()
