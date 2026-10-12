#!/usr/bin/env python3
"""Prepare matched two-cut timing measurements with the existing resource guard.

No launch here. Preserve the measured parent's complete native process lifecycle.
The canonical FAIL remains a FAIL; these runs measure an unqualified candidate.
"""
import argparse
import ast
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import sha, replace, span
from freeze_mc_pair_srt_rk_candidate import CHANGES, PARENT

REPO = Path(__file__).resolve().parents[1]
TEMPLATES = {
    'synthesis-r2/run.py': '7ae78860eb64ebf8d92b3450cda700a6b94d7fb2eda01eb6391ffbb9fb637b34',
    'synthesis-r2/audit_closed.py': 'c8cfdc4454356c35405b263b5602874ca2af4ea2e834f319e44f0e01bb79c2dd',
    'clock-r2/run.py': '659af937193f8926415cba71794845b2c386d91c3393235192698d2291d38d34',
    'clock-r2/audit_closed.py': '172aa7697b62097db3d5dd5c59bc9c9cca4fd299ca5c37c4210a20d912e035fe',
    'clock-r2/audit.tcl': 'f766d944965316620332486e69c5fb5863b1493138ba7f7aa135bd5e30cb970a',
    'after_prepare_synth_r2.py': 'ef4b59de8bf591e6688dc14437f72e9993caa9fd3828fe6d2c94ea49189dae5f',
}
PROOF = """core=load_proof('core-r1/prepared.json')
assert core['changes']==['rtl/core/core.sv','rtl/fpu/fpu_srt_div.sv']
assert core['inherited_engine_operations']==4544 and core['inherited_engine_cycle_checks']==162282
assert core['inherited_pair_response_clocks']==77834
assert all(sha(path)==digest for path,digest in core['pins'].items())
pins.update(core['pins'])
replay=load_proof('canonical-same-input/closed.json')
assert replay['same_input_regression_passed'] and replay['pins_unchanged'] and not replay['errors']
assert len(replay['rows'])==108 and replay['records']==80800 and not replay['canonical_gate_passed']
for name in ('canonical-same-input','debug-r1','fault-r1'):
    checked=load_proof(name+'/closed.json')
    before=load_proof(name+'/started.json')
    assert checked['pins_unchanged'] and not checked['errors']
    if name!='canonical-same-input': assert checked['passed']
    assert all(sha(path)==digest for path,digest in before['pins'].items())
    pins.update(before['pins'])
fault=load_proof('fault-r1/closed.json')
assert len(fault['measurements'])==32
assert all(sha(proof/'fault-r1'/path)==digest for path,digest in fault['artifacts'].items())
resume=load_proof('resume-r2/closed.json')
assert resume['passed'] and resume['pins_unchanged'] and not resume['errors']
assert not resume['canonical_gate_passed'] and resume['no_synthesis_or_implementation']
"""


def derive(original, resume_invocation):
    assert len(resume_invocation) == 32 and all(c in '0123456789abcdef' for c in resume_invocation)
    result = {}
    for name in ('synthesis-r2/run.py', 'clock-r2/run.py'):
        text = original[name]
        for label in ('synth', 'clock'):
            text = text.replace('ventium-mc-read-'+label+'-r2-oct11.service',
                                'ventium-mc-pair-srt-'+label+'-oct12.service')
        text = replace(text, "manifest['variant'] == 'mc_read_commit'",
                       "manifest['variant'] == 'mc_pair_srt_timing'")
        if name.startswith('synthesis'):
            text = span(text, "leaf=load_proof('leaf-r2/closed.json')\n", "for name in ('memory-r1'", PROOF)
            text = replace(text, "prepared['changes']==['rtl/core/core_mem_chain.svh']",
                           "prepared['changes']==['rtl/core/core.sv','rtl/fpu/fpu_srt_div.sv']")
            text = replace(text, "load_proof('timing-retry-prepared.json')\n", '')
            rationale = ('Measure combined SRT normalization and response-read commit cuts against the '
                '29.58405 MHz MC parent. Exactly two RTL deltas, unchanged UV+fast modes, full P5 caches, '
                'clocks and logic-only mapper. Whole-core state/cycle, fault and short CoreMark checks '
                'passed; canonical gate remains FAIL. No release or hardware acceptance inherited.')
            text = span(text, '    rationale=', '    generic_gate=', '    rationale='+repr(rationale)+',\n')
        else:
            text = replace(text, "synthesis = root.parent/'synthesis-r2'", "synthesis = root.parent/'synthesis'")
            text = replace(text, 'ventium-pair-ready-cofactor.btYwXlBN/synthesis',
                           'ventium-mc-read-commit.PNi1O0xm/synthesis-r2')
            text = replace(text, '51832e2844ec3bcd8ad456d3a552a74aae49642fc00e425aa313329e07ea4b99',
                           '9262331c62aa74413bbf5a785e927fcdea1a425507941bcf1d3f94c449bf8d15')
        boundary = 'owner = None\n'
        assert text[text.index(boundary):] == original[name][original[name].index(boundary):]
        for guard in ("VENTIUM_VIVADO_MEMORY_MAX='8G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'",
                      'if free < 4*gib:', 'memory+swap > 13*gib', 'min(host.values()) < 2*gib'):
            assert guard in text
        result[name.replace('-r2/', '/')] = text
    text = original['synthesis-r2/audit_closed.py']
    text = replace(text, 'ventium-pair-ready-cofactor.btYwXlBN/synthesis',
                   'ventium-mc-read-commit.PNi1O0xm/synthesis-r2')
    text = replace(text, 'ventium-pair-ready-cofactor.btYwXlBN/fpga-r1',
                   'ventium-mc-read-commit.PNi1O0xm/fpga-r1')
    text = replace(text, 'ventium-mc-read-synth-r2-oct11.service', 'ventium-mc-pair-srt-synth-oct12.service')
    text = replace(text, '2d573cb347eaa630a7010f197d2ee0788f2aeef8340c6bb24d06767dd9712ece', PARENT)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    text = replace(text, 'matched_profile_mc_read_commit=True', 'matched_profile_mc_pair_srt_timing=True')
    text = replace(text, 'Audit the read-only hint commit against the measured readiness parent.',
                   'Audit exactly two timing deltas against the measured MC parent.')
    result['synthesis/audit_closed.py'] = text
    text = replace(original['clock-r2/audit_closed.py'], 'ventium-mc-read-clock-r2-oct11.service',
                   'ventium-mc-pair-srt-clock-oct12.service')
    result['clock/audit_closed.py'] = replace(text, '(-7.951)', '(-8.802)')
    result['clock/audit.tcl'] = original['clock-r2/audit.tcl']
    text = original['after_prepare_synth_r2.py']
    text = replace(text, "root==scratch/'ventium-mc-read-commit.PNi1O0xm'",
                   "root==scratch/'ventium-mc-pair-srt.fI8m6eUS'")
    text = replace(text, "work=root/'timing-queue-r2'", "work=root/'timing-queue'")
    text = replace(text, "unit='ventium-mc-read-'+label+'-r2-oct11.service'",
                   "unit='ventium-mc-pair-srt-'+label+'-oct12.service'")
    text = replace(text, "directory='synthesis-r2' if label=='synth' else 'clock-r2'",
                   "directory='synthesis' if label=='synth' else 'clock'")
    text = text.replace("'synthesis-r2/", "'synthesis/").replace("'clock-r2/", "'clock/")
    preflight = f"""    wait('ventium-mc-pair-srt-resume-r2-oct12.service',{resume_invocation!r},2900)
    assert load(root/'resume-r2/closed.json')['passed']
    assert load(root/'soc-r1/coremark/audit.json')['passed']
    assert load(root/'lint-r1/closed.json')['passed']
    model=load(root/'soc-r1/build-closed.json')['binary_sha256']
    manifest=load(root/'fpga-r1/freeze-receipt.json')['manifest_sha256']
    assert sha(root/'fpga-r1/input-manifest.json')==manifest
"""
    result['after_prepare_synth.py'] = span(text, "    wait('ventium-mc-read-soc-queue-oct11.service'",
                                          "    launch('synth',3100,manifest,model)", preflight)
    for name, text in result.items():
        if name.endswith('.py'):
            ast.parse(text, filename=name)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--resume-invocation', required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.root.resolve(strict=True)
    parent = scratch/'ventium-mc-read-commit.PNi1O0xm'
    assert __debug__ and root == scratch/'ventium-mc-pair-srt.fI8m6eUS'
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    manifest = json.loads((root/'fpga-r1/freeze-receipt.json').read_text())['manifest_sha256']
    model = json.loads((root/'soc-r1/build-closed.json').read_text())['binary_sha256']
    assert sha(root/'fpga-r1/input-manifest.json') == manifest
    assert sha(root/'soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == model
    original = {}
    for name, digest in TEMPLATES.items():
        assert sha(parent/name) == digest
        original[name] = (parent/name).read_text()
    outputs = derive(original, args.resume_invocation)
    assert not (root/'timing-prepared.json').exists()
    assert all(not (root/name).exists() for name in outputs)
    for name, text in outputs.items():
        path = root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as stream:
            stream.write(text)
    pins = {str(parent/name): digest for name, digest in TEMPLATES.items()}
    for path in (Path(__file__), REPO/'fpga/prepare_fragment_exact_timing.py',
                 REPO/'fpga/freeze_mc_pair_srt_rk_candidate.py'):
        pins[str(path)] = sha(path)
    receipt = dict(passed=True, controllers_generated_not_launched=True, template_pins=pins,
        outputs={str(root/name): sha(root/name) for name in outputs}, unchanged_guard_lifecycle=True,
        source_manifest_sha256=manifest, model_sha256=model, canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, gameplay_ipc=None)
    with (root/'timing-prepared.json').open('x') as stream:
        json.dump(receipt, stream, indent=2)
    print(json.dumps({k: v for k, v in receipt.items() if k not in ('template_pins', 'outputs')}))


if __name__ == '__main__':
    main()
