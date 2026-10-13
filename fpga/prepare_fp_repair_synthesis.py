"""Prepare guarded, matched synthesis/timing for the tested general repairs.

Launch nothing. Preserve the closed endpoint parent's lifecycle and resource
limits byte-for-byte; only source identities and diagnostic evidence change.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_fp_repair_soc as native
import fp_repair_hardware as hardware
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

SCRATCH = Path('/home/yukidama/external/tmp').resolve(strict=True)
PARENT = SCRATCH / 'ventium-load-read-ack.GyWDDtiI'
MANIFEST = 'bf2a944dc6aedaa7ec406fdf5c5607c54d707b8cb04fa25ad88b6ba74fac9b93'
MODEL = 'c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd'
PARENT_MANIFEST = 'c45c29a6b2ae32fdd34defe85a6922e8560b2ccb9054b5d1563ae773a9040bd1'
PARENT_DCP = 'b84da6e30f8b87f26bcc86f03d23a8df44644fb272af8713316d3472721d2d12'
TEMPLATES = {
    'endpoint-map-synthesis-r1/run.py': 'f746a7cfb9192a8316c736ab857e75eaec384fe5379413d498ffdbeb3931b432',
    'endpoint-map-synthesis-r1/audit_closed.py': '3dfa0a95bd738818758a96dd1daf5f0d32495f0ce47c43b03e62940ec09752eb',
    'endpoint-map-clock-r1/run.py': '798efdff2253d0ac01d9e4cdf1d0077f42b74cf95329f0a74ee4c21e21c87b6e',
    'endpoint-map-clock-r1/audit_closed.py': 'a4d67fd4c1115100adb7e376c9cbdfb9b96860ee8de067f0ec943ba54c5e7d6c',
    'endpoint-map-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
CHANGES = {'ventium/' + n: h for n, h in native.recipe.RESULTS.items()}
CHANGES.update({
    'ventium/rtl/core/core_exec.svh': '384781e0f3e5d0fee80c10296004ad6154179d6d7eaa155677c606d659a66354',
    'ventium/rtl/core/core_fetch_decode.svh': 'd109aa12a2fa0a37ca75bd1fa1e2b5e72d8b0aaa7774ada032f283234ebc0517',
    'ventium/rtl/core/core_refdecode_latch.svh': '411291532534376d7fc122d693de4d373cd4fa7788490649011cc5e642a15319',
    'ventium/rtl/core/decode_stages.sv': '1ca62ee810707834a93ad49c1c79e8c2fee7a1bb57cdd000829f9ff22a51ed86',
})

PROOF = '''import sys
sys.path.insert(0,str(repo/'fpga'))
import build_fp_repair_soc as native
prepared=load_proof('soc-r1/prepared.json')
assert len(prepared['intersecting_rtl_sources'])==102 and prepared['changes']==native.CHANGES
assert prepared['added_defines']==[] and prepared['directed_model']==native.CORE_MODEL
assert prepared['single_fill_model']==native.BOARD_MODEL and prepared['functional_corpus_passed']
assert not prepared['canonical_gate_passed'] and prepared['qualification']=='UNQUALIFIED'
pins.update(prepared['pins'])
core=Path(prepared['directed_core'])
for name in prepared['intersecting_rtl_sources']:
    assert sha(proof/'soc-r1/source'/name)==sha(core/'candidate'/name)
for name in prepared['changes']:
    before=(Path(prepared['parent'])/'source'/name).read_text()
    assert native.recipe.transform(before,name)==(proof/'soc-r1/source'/name).read_text()
funcproof=Path('/home/yukidama/external/tmp/ventium-cycle-backend.VAI7femO/audit.json').resolve(strict=True)
assert sha(funcproof)==native.AUDIT
func=json.loads(funcproof.read_text())
assert func['audit_passed'] and func['functional_passes']==108 and func['functional_records']==80800
assert func['functional_v_retirements']==30134 and func['unmasked_functional_passes']==105
assert func['cycle_runs']==88 and not func['canonical_gate_passed'] and not func['hardware_acceptance']
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
        old = original['endpoint-map-' + phase + '-r1/run.py']
        text = replace(old, "root.parent/'endpoint-map-fpga-r1'", "root.parent/'fpga-r1'")
        text = replace(text, "root.parent/'endpoint-map-lint-r1/closed.json'", "root.parent/'lint-r1/closed.json'")
        text = text.replace('ventium-endpoint-map-', 'ventium-fp-repair-')
        text = replace(text, "manifest['variant'] == 'endpoint_map_timing'", "manifest['variant'] == 'fp_general_repairs_timing'")
        text = replace(text, "generic_gate='FAIL; no masks or cycle bands waived; CPU lint alone passed'",
                       "generic_gate='FUNC 108/108 with existing masks; cycle/fault gates remain red; CPU lint only, not full SoC or suite'")
        if phase == 'synthesis':
            text = span(text, 'import sys\nsys.path.insert', "cmroot=root.parent/'endpoint-map-soc-r1/coremark'", PROOF)
            text = replace(text, "cmroot=root.parent/'endpoint-map-soc-r1/coremark'", "cmroot=root.parent/'soc-r1/coremark'")
            text = replace(text, 'Measure the source-matched SMSW repair plus parallel endpoint map; no route or deployment.',
                           'Measure the source-matched general ISA/x87 repairs and segment-extent rewrite; no route or deployment.')
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Measure the tested LMSW, obsolete-x87, FP environment and FRNDINT repairs plus segment-extent rewrite. The matched endpoint parent estimates 35.056967572 MHz. Same 158 hardware defines, UV-fast/full P5 caches, posted-16 transport, logic-only mapper and 40/100 MHz constraints. Functional corpus and short CoreMark pass; cycle/fault gates, full suite and physical acceptance remain open. No isolated gain or sign-off is presumed.',\n")
            guarded(text, old)
        else:
            text = replace(text, "root.parent/'endpoint-map-synthesis-r1'", "root.parent/'synthesis-r1'")
            text = replace(text, str(PARENT/'prime-reg-synthesis-r1'), str(PARENT/'endpoint-map-synthesis-r1'))
            text = replace(text, '66ff1ad84d0b4f64926b0cec6df965a0a54bbca60c49185b9799c69f454eb1da', PARENT_DCP)
            clock_guarded(text, old)
        result[phase + '-r1/run.py'] = text
    text = original['endpoint-map-synthesis-r1/audit_closed.py']
    text = replace(text, "root.parent / 'endpoint-map-fpga-r1'", "root.parent / 'fpga-r1'")
    for suffix in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(PARENT/('prime-reg-'+suffix)), str(PARENT/('endpoint-map-'+suffix)))
    text = replace(text, 'ventium-endpoint-map-synth-oct13.service', 'ventium-fp-repair-synth-oct13.service')
    text = replace(text, '3725586f494f96210da1c1f15ef56c614bcd8a3b41dbd042b02ffded7d964cd0', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    text = replace(text, 'four-file SMSW and endpoint-map transfer', 'eight-file general repair transfer')
    result['synthesis-r1/audit_closed.py'] = text
    text = original['endpoint-map-clock-r1/audit_closed.py']
    text = replace(text, 'ventium-endpoint-map-clock-oct13.service', 'ventium-fp-repair-clock-oct13.service')
    result['clock-r1/audit_closed.py'] = replace(text, '(-3.552)', '(-3.525)')
    result['clock-r1/audit.tcl'] = original['endpoint-map-clock-r1/audit.tcl']
    for name, text in result.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root == SCRATCH/'ventium-fp-repair-transfer.a8nzrjHu'
    assert Path(os.environ['TMPDIR']).resolve() == SCRATCH
    source = root/'fpga-r1'
    assert sha(source/'input-manifest.json') == MANIFEST
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    assert set(manifest['changed_parent_payloads']) == set(CHANGES)
    assert set(CHANGES) == {'ventium/'+n for n in hardware.CHANGES}
    assert sha(root/'soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    for name, digest in CHANGES.items():
        assert sha(source/name) == digest
        assert hardware.transform((PARENT/'endpoint-map-fpga-r1'/name).read_text(),
                                  name.removeprefix('ventium/')) == (source/name).read_text()
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        path = PARENT/name
        assert sha(path) == digest
        original[name] = path.read_text(); pins[str(path)] = digest
    for path in (Path(__file__), Path(native.__file__), Path(hardware.__file__),
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
    print('Prepared guarded general-repair synthesis/timing; nothing launched.', flush=True)


if __name__ == '__main__': main()
