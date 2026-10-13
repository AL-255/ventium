"""Prepare source-matched current-tag timing with unchanged resource guards.

This creates controllers only. Native launch separately requires closed short
CoreMark checks, strict CPU lint, source pins and disk/RAM admission.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_window_current_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

SCRATCH = Path('/home/yukidama/external/tmp').resolve(strict=True)
ROOT = SCRATCH / 'ventium-data-size.v2HaTO2X'
PRIOR = SCRATCH / 'ventium-fp-repair-transfer.a8nzrjHu'
MANIFEST = '09160fa65d1b67dcfd9bc263715c5b73475c04410991a3941e651f3eb59fa7c8'
MODEL = 'da16060952d983b02d4373038e3faccc5cc8d577e7635c3ae1d104314c08098e'
PARENT_MANIFEST = '8e8ab037834da5120453149a60766b4455f60be0e14e06f6a7be33a19aa5b864'
PARENT_DCP = 'e1d89ee8d386289e4d29bf4c89304800d68f7d2999762061dc929983abdb58c8'
CHANGES = {
    'ventium/rtl/core/decode_stages.sv': 'e961f42125090b880ec06cddd1c9d2414af2f0a458e3fb008d39325b2b085292',
    'ventium/rtl/mem/ven_l1d.sv': 'a0d3ed6f8fc725975a6833facd4c87adb5ee8f8114d6dd0ea9fbb6b3982d44bf',
}
TEMPLATES = {
    'synthesis-r1/run.py': '360f144c622139e0044ae51888a786b6d7517d68bf45b28af64ada3527ca8ad8',
    'synthesis-r1/audit_closed.py': '04d565747a743b649b95bffb265d50a12293df131730a4ceb1ab1c6a74ea494b',
    'clock-r1/run.py': '7c5482eab2ebdbff495e84f2dd59233a9fac8bb9d1500d48d78aa399763d7145',
    'clock-r1/audit_closed.py': '0eef87a9d01f16ef657b1aef53a6fabc1757051130d150a06e0569723137ba9b',
    'clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
PROOF = '''import sys
sys.path.insert(0,str(repo/'fpga'))
import build_window_current_soc as native
prepared=load_proof('window-current-soc-r1/prepared.json')
assert len(prepared['intersecting_rtl_sources'])==102 and prepared['changes']==native.CHANGES
assert prepared['added_defines']==[] and prepared['directed_model']==native.CORE_MODEL
assert prepared['parent_model']==native.PARENT_MODEL and prepared['functional_corpus_passed']
assert not prepared['canonical_gate_passed'] and prepared['qualification']=='UNQUALIFIED'
pins.update(prepared['pins'])
core=Path(prepared['directed_core'])
for name in prepared['intersecting_rtl_sources']:
    assert sha(proof/'window-current-soc-r1/source'/name)==sha(core/'candidate'/name)
for name in prepared['changes']:
    before=(Path(prepared['parent'])/'source'/name).read_text()
    assert native.transform(name,before)==(proof/'window-current-soc-r1/source'/name).read_text()
funcproof=proof/'window-current-regression-audit.json'
assert sha(funcproof)=='1dd4b7175a442465dac426b026255b283acfd9d985bda1d9e7893b5872cddf28'
func=json.loads(funcproof.read_text())
assert func['audit_passed'] and func['functional_passes']==108 and func['functional_records']==80800
assert func['v_retirements']==30132 and func['unmasked_functional_passes']==105
assert func['parent_v_retirements']==30132 and not func['pair_deltas'] and func['cycle_traces_unchanged']==20
assert not func['canonical_gate_passed'] and not func['physical_board']
pins.update(func['artifacts']); pins[str(funcproof)]=sha(funcproof)
fault=load_proof('window-current-env-fault-r2/closed.json')
assert fault['passed'] and fault['pins_unchanged'] and not fault['errors'] and len(fault['rows'])==44
assert all(r['passed'] and r['golden_exit']==0 and len(r['rows'])==2 and all(
    x['rtl_self_check'] and x['compare_exit']==0 and x['paired_v']>0 and x['backing_acks']>0
    for x in r['rows']) for r in fault['rows'])
pins.update(load_proof('window-current-env-fault-r2/started.json')['pins'])
pins.update({str(proof/'window-current-env-fault-r2'/p):h for p,h in fault['artifacts'].items()})
pc=load_proof('window-current-soc-r1/build-closed.json')
assert pc['passed'] and pc['native_exit']==0 and pc['inputs_unchanged'] and not pc['errors']
assert pc['binary_sha256']==model and pc['structural_warnings_unchanged'] and pc['structural_debt_count']==98
timing=load_proof('window-current-timing-prepared.json')
assert timing['unchanged_guard_lifecycle'] and timing['controllers_generated_not_launched']
assert timing['source_manifest_sha256']==manifest_sha and timing['model_sha256']==model
pins.update(timing['template_pins']); pins.update(timing['outputs'])
assert all(sha(p)==h for p,h in pins.items())
'''


def derive(original):
    result = {}
    for phase in ('synthesis', 'clock'):
        old = original[phase + '-r1/run.py']
        text = old.replace('ventium-data-size-', 'ventium-window-current-')
        text = replace(text, "source = root.parent/'fpga-r1'", "source = root.parent/'window-current-fpga-r1'")
        text = replace(text, "root.parent/'lint-r1/closed.json'", "root.parent/'window-current-lint-r1/closed.json'")
        text = replace(text, "manifest['variant'] == 'data_size_timing'", "manifest['variant'] == 'window_current_timing'")
        if phase == 'synthesis':
            text = span(text, 'import sys\nsys.path.insert', "cmroot=root.parent/'soc-r1/coremark'", PROOF)
            text = replace(text, "cmroot=root.parent/'soc-r1/coremark'", "cmroot=root.parent/'window-current-soc-r1/coremark'")
            text = replace(text, 'Measure the source-matched data-size cofactor; no route or deployment.',
                           'Measure the source-matched saved-window current-tag cofactor; no route or deployment.')
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Current idle reads exclude prime lookup: select current tags directly for primary/shadow saved-window reuse while retaining next-owner arbitration and every cache guard. The matched data-size parent estimates 35.830735605 MHz. Include the independently tested general x87 environment-write classification repair. Exactly two RTL files change; unchanged 158 hardware definitions, full P5 caches, UV-fast, posted-16 and 40/100 MHz constraints. No added cycles, guest patch or timing exception. Canonical, full-suite and physical acceptance remain open.',\n")
            guarded(text, old)
        else:
            text = replace(text, "synthesis = root.parent/'synthesis-r1'", "synthesis = root.parent/'window-current-synthesis-r1'")
            text = replace(text, str(PRIOR/'synthesis-r1'), str(ROOT/'synthesis-r1'))
            text = replace(text, 'd801ced570e78057204df123ad72a899b0dc2ed6ed5e22490efdaa0ce61d1b97', PARENT_DCP)
            clock_guarded(text, old)
        result['window-current-' + phase + '-r1/run.py'] = text
    text = original['synthesis-r1/audit_closed.py']
    text = replace(text, "source = root.parent / 'fpga-r1'", "source = root.parent / 'window-current-fpga-r1'")
    for suffix in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(PRIOR/suffix), str(ROOT/suffix))
    text = replace(text, 'ventium-data-size-synth-oct13.service', 'ventium-window-current-synth-oct13.service')
    text = replace(text, 'bf2a944dc6aedaa7ec406fdf5c5607c54d707b8cb04fa25ad88b6ba74fac9b93', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    result['window-current-synthesis-r1/audit_closed.py'] = replace(text, 'one-file data-size transfer', 'two-file environment-write/current-tag transfer')
    text = original['clock-r1/audit_closed.py']
    text = replace(text, 'ventium-data-size-clock-oct13.service', 'ventium-window-current-clock-oct13.service')
    result['window-current-clock-r1/audit_closed.py'] = replace(text, '(-2.889)', '(-2.909)')
    result['window-current-clock-r1/audit.tcl'] = original['clock-r1/audit.tcl']
    for name, text in result.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == SCRATCH
    source = root/'window-current-fpga-r1'
    assert sha(source/'input-manifest.json') == MANIFEST
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    assert set(manifest['changed_parent_payloads']) == set(CHANGES)
    assert sha(root/'window-current-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    for name, digest in CHANGES.items():
        assert sha(source/name) == digest
        assert native.transform(name.removeprefix('ventium/'),(root/'fpga-r1'/name).read_text()) == (source/name).read_text()
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        path = ROOT/name
        assert sha(path) == digest
        original[name] = path.read_text(); pins[str(path)] = digest
    for path in (Path(__file__), Path(native.__file__), Path(native.window.__file__), Path(native.env_write.__file__),
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py'),
                 Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(path.resolve())] = sha(path)
    outputs = derive(original)
    assert not (root/'window-current-timing-prepared.json').exists()
    assert all(not (root/name).exists() for name in outputs)
    for name, text in outputs.items():
        path = root/name; path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as f: f.write(text)
    with (root/'window-current-timing-prepared.json').open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n):sha(root/n) for n in outputs},
            source_manifest_sha256=MANIFEST, model_sha256=MODEL, canonical_gate_passed=False,
            standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None), f, indent=2)
    print('Prepared guarded current-tag synthesis/timing; nothing launched.', flush=True)


if __name__ == '__main__': main()
