#!/usr/bin/env python3
"""Freeze guarded synthesis and read-only timing audits for the combined cuts.

The exact completed PRIME templates supply the process/resource lifecycle.
Only source/proof identities and comparisons change. This command launches
nothing; the resulting synthesis still requires native closure and timing audit.
"""
import argparse
import ast
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import replace, sha, span

MANIFEST = '1f78fbf6d9384f8e79a558f25d6e2b9a2b3e3a7a286fd8100f3f8764daca87f2'
MODEL = '0910a3be8bf6c3a5d293dfd8204e0be89e98bb1163a4f2eb6e73f547ddff133a'
TEMPLATE_ROOT = Path('/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS')
TEMPLATES = {
    'synthesis-logic-r1/run.py': 'fc53a7110e2ffb0996aa219207199c44691b49cfe54ab124b77e04148ad941db',
    'synthesis-logic-r1/audit_closed.py': 'd1e219f285c42502fafed1c566cee25284840bf77abcbad2a82e302b1d811d44',
    'clock-logic-r1/run.py': 'ec48cbfef92b7ae710d7a13fd63d6627c0109cfe8ed8c860049c19d557642ecb',
    'clock-logic-r1/audit_closed.py': 'ddac09ec01ad9d35fa7a1db827c3dd852d590b231f1ea5bebd2db7b04a575faf',
    'clock-logic-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
CHANGES = {
    'ventium/rtl/core/core.sv': 'e2fb72e5e10785cde9a0992da432bf0c7e06b6d386dc13bed230b440d24d48a1',
    'ventium/rtl/mem/ven_l1d.sv': 'c82bf532dfcf80a5c40431fa1f818cb45992745914faf280ef4af58a20477393',
    'ventium/rtl/mem/ventium_l1_axi.sv': 'b0bdb4656083d8727264be4f9130dd9fb8b3384cc712cc3a76352af90cf7c95d',
    'ventium/rtl/ventium_top.sv': 'e28b4151744bd07a3e68822977b01c8e79992f42f369959d89437dbd87b1f7ab',
}
PROOF = '''verify=load_proof('payload-current-core-r1/verify-closed.json')
assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']
assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
assert len(verify['deltas'])==20 and all(row['same_records'] for row in verify['deltas'])
core=load_proof('payload-current-core-r1/prepared.json')
changes=['rtl/core/core.sv', 'rtl/mem/ven_l1d.sv', 'rtl/mem/ventium_l1_axi.sv', 'rtl/ventium_top.sv']
assert core['changes']==changes and len(core['definitions'])==151
build=load_proof('payload-current-core-r1/build-closed.json')
assert build['passed'] and build['native_exit']==0 and build['pins_unchanged'] and not build['errors']
assert build['binary_sha256']=='fbe7b4e3b31c83396414de6802fe2e06dd4be0d4b039199dfc0f8e660154c8d6'
pins.update(core['pins'])
replay=load_proof('payload-current-canonical-ab-r1/closed.json')
assert replay['same_input_regression_passed'] and replay['pins_unchanged'] and not replay['errors']
assert len(replay['rows'])==108 and replay['records']==80800 and not replay['canonical_gate_passed']
pins.update(load_proof('payload-current-canonical-ab-r1/started.json')['pins'])
prepared=load_proof('payload-current-soc-r1/prepared.json')
assert len(prepared['intersecting_rtl_sources'])==102 and prepared['changes']==changes
assert prepared['added_defines']==['VEN_L1D_PAYLOAD_CODE_HINT']
assert prepared['directed_model']==build['binary_sha256']
pins.update(prepared['pins'])
pc=load_proof('payload-current-soc-r1/build-closed.json')
assert pc['passed'] and pc['native_exit']==0 and pc['inputs_unchanged'] and not pc['errors']
assert pc['binary_sha256']==model and pc['structural_warnings_unchanged']
assert pc['structural_debt_count']==98
timing=load_proof('payload-current-timing-prepared.json')
assert timing['unchanged_guard_lifecycle'] and timing['controllers_generated_not_launched']
pins.update(timing['template_pins'])
pins.update(timing['outputs'])
assert all(sha(p)==h for p,h in pins.items())
'''


def guarded(text, original):
    boundary = 'owner = None\n'
    assert text[text.index(boundary):] == original[original.index(boundary):]
    for invariant in ("VENTIUM_VIVADO_MEMORY_MAX='8G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'",
                      'memory+swap > 13*gib', 'if free < 4*gib:', 'min(host.values()) < 2*gib',
                      "VEN_FPGA_CORE_MHZ='40'", "VEN_FPGA_BUILD_PROFILE='logic_only'"):
        assert invariant in text


def derive(original, parent):
    result = {}
    for phase in ('synthesis', 'clock'):
        name = phase+'-logic-r1/run.py'
        text = original[name]
        text = replace(text, "source = root.parent/'fpga-r1'", "source = root.parent/'payload-current-fpga-r1'")
        text = text.replace('ventium-prime-noack-logic-', 'ventium-payload-current-')
        text = replace(text, "manifest['variant'] == 'prime_noack_timing'", "manifest['variant'] == 'payload_current_timing'")
        text = replace(text, "manifest['source_contract_synthesis_profile'] == 'balanced'",
                       "manifest['source_contract_synthesis_profile'] == 'logic_only'")
        text = replace(text, "len(manifest['hardware_defines']) == 156", "len(manifest['hardware_defines']) == 157")
        text = replace(text, "root.parent/'lint-r1/closed.json'", "root.parent/'payload-current-lint-r1/closed.json'")
        if phase == 'synthesis':
            text = span(text, "verify=load_proof('core-r1/verify-closed.json')", "cmroot=root.parent/'soc-r1/coremark'", PROOF)
            text = replace(text, "cmroot=root.parent/'soc-r1/coremark'", "cmroot=root.parent/'payload-current-soc-r1/coremark'")
            # Keep the parent's conservative measured-growth admission unchanged.
            rationale = ('Measure the combined read-only I-fill ACK, bank-overlap and payload-kind cuts. '
                'Same Default logic-only mapper and actual 40/100 MHz clocks as the 28.88420323 MHz parent. '
                '157 definitions (only payload hint added), UV+fast mode and full P5 caches retained. '
                'Directed checks and short CoreMark pass; canonical gate still FAIL. '
                'No standard-suite, route, board or Fmax acceptance is inherited.')
            text = span(text, '    rationale=', '    generic_gate=', '    rationale='+repr(rationale)+',\n')
        else:
            text = replace(text, "synthesis = root.parent/'synthesis-logic-r1'", "synthesis = root.parent/'payload-current-synthesis-r1'")
            text = replace(text, str(TEMPLATE_ROOT/'synthesis'), str(parent/'synthesis-logic-r1'))
            text = replace(text, 'edeeb26299d0cb2b85e71a1567e09440e566726e544d0c4c084a520d28a93ffd',
                           '2a734a6d33ff623254a88e2fa3ec40078d340ed45533e0f02c9767694f36661b')
        guarded(text, original[name])
        result['payload-current-'+phase+'-r1/run.py'] = text

    text = original['synthesis-logic-r1/audit_closed.py']
    text = replace(text, "source = root.parent / 'fpga-r1'", "source = root.parent / 'payload-current-fpga-r1'")
    text = replace(text, str(TEMPLATE_ROOT/'synthesis'), str(parent/'synthesis-logic-r1'))
    text = replace(text, str(TEMPLATE_ROOT/'fpga-r1'), str(parent/'fpga-r1'))
    text = replace(text, 'ventium-prime-noack-logic-synth-oct12.service', 'ventium-payload-current-synth-oct12.service')
    text = replace(text, '43e940607586e889fe85185d4a12effcc083a1f92b32b7130fc0704304fe48b7',
                   '485aec1484e25676312315347b406a80122f2e58a13065f8bdf39ac1f089a755')
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    text = replace(text, "assert manifest['hardware_defines'] == old_manifest['hardware_defines']",
        "assert manifest['hardware_defines'].count('VEN_L1D_PAYLOAD_CODE_HINT') == 1\n"
        "assert manifest['hardware_defines'].index('VEN_L1D_PAYLOAD_CODE_HINT') == 153\n"
        "assert [d for d in manifest['hardware_defines'] if d != 'VEN_L1D_PAYLOAD_CODE_HINT'] == old_manifest['hardware_defines']")
    text = replace(text, "len(manifest['hardware_defines']) == 156", "len(manifest['hardware_defines']) == 157")
    text = replace(text, 'actual_defines=156', 'actual_defines=157')
    text = replace(text, 'same_clocks_and_defines=True',
        "same_clocks=True, only_added_define='VEN_L1D_PAYLOAD_CODE_HINT', parent_defines_retained=True")
    text = replace(text, 'No new defines, clock changes, timing waiver or inherited suite acceptance.',
        'Only the checked payload hint define is added; no clock change or timing waiver.')
    result['payload-current-synthesis-r1/audit_closed.py'] = text
    text = original['clock-logic-r1/audit_closed.py']
    text = replace(text, 'ventium-prime-noack-logic-clock-oct12.service', 'ventium-payload-current-clock-oct12.service')
    text = replace(text, '(-9.616)', '(-9.621)')
    result['payload-current-clock-r1/audit_closed.py'] = text
    result['payload-current-clock-r1/audit.tcl'] = original['clock-logic-r1/audit.tcl']
    for name, text in result.items():
        if name.endswith('.py'):
            ast.parse(text, filename=name)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    root = args.root.resolve(strict=True)
    assert __debug__ and root == scratch/'ventium-mc-pair-srt.fI8m6eUS'
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    parent = root/'prime-noack'
    assert sha(root/'payload-current-fpga-r1/input-manifest.json') == MANIFEST
    assert sha(root/'payload-current-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    original = {}
    pins = {}
    for name, digest in TEMPLATES.items():
        path = parent/name
        assert sha(path) == digest, str(path)
        original[name] = path.read_text()
        pins[str(path)] = digest
    for path in (Path(__file__).resolve(), Path(__file__).with_name('prepare_fragment_exact_timing.py')):
        pins[str(path)] = sha(path)
    result = derive(original, parent)
    receipt = root/'payload-current-timing-prepared.json'
    assert not receipt.exists()
    assert all(not (root/name).exists() for name in result)
    for name, text in result.items():
        path = root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as output:
            output.write(text)
    data = dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
        template_pins=pins, outputs={str(root/name): sha(root/name) for name in result},
        source_manifest_sha256=MANIFEST, model_sha256=MODEL, canonical_gate_passed=False,
        standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None)
    with receipt.open('x') as output:
        json.dump(data, output, indent=2)
    print(json.dumps({k:v for k,v in data.items() if k not in ('outputs','template_pins')}))


if __name__ == '__main__':
    main()
