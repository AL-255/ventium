"""Prepare one matched early-bus timing experiment; launches nothing.

Retain the closed predecessor's exclusive Vivado ownership and resource/wait
controls byte-for-byte. No RTL delta beyond the tested bus-driver rewrite.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_early_bus_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
MANIFEST = '9ec9a00dc8a73884074f6ea5e01ba9925f3725bc90425693b974d38fc061e5e7'
MODEL = '593833e1650b5869373abbd74debcc63d15ea53eca1aa87f62e833982ead2fe9'
PARENT_MANIFEST = '36908a9d96c4ddca51d143f634acacc85c067bfeb1aaf24833a9eda99fb6a7dc'
PARENT_DCP = 'd8365bb3948afaf521abd8a3c9d282e5a10ae9a50e456e678d75a86eab671fae'
TEMPLATES = {
    'decode-bus-synthesis-r1/run.py': '4ed7062f0ea678e05924d36154015e46c9395d22f1c4147813af96171a0d4e91',
    'decode-bus-synthesis-r1/audit_closed.py': '469f29c8f61218d1074317cee19b621c583e97395fbd78e710f2df0697fa4c33',
    'decode-bus-clock-r1/run.py': 'f150c0e14a93634567357ca911b2e9c13b0a7d0dcdde278e739c1e1e6ba3b730',
    'decode-bus-clock-r1/audit_closed.py': '6d0f1bc30b3ebfaee01a34ed1292bfe1d91ca2985369d0ba2895e468abb07c72',
    'decode-bus-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def common(text):
    return (text.replace('decode-bus-', 'early-bus-')
        .replace('decode_bus_payload_timing', 'early_bus_payload_timing')
        .replace('build_decode_bus_soc', 'build_early_bus_soc'))


def derive(original, changes):
    assert set(changes) == {'ventium/'+native.recipe.FILE}
    outputs = {}
    old = original['decode-bus-synthesis-r1/run.py']
    text = common(old)
    text = replace(text, 'Measure DECODE bus payload and strict x87 policy; no route or deployment.',
                   'Measure early bus payload; same strict x87 policy, no route or deployment.')
    text = replace(text, "prepared['added_defines']==[native.FLAG]", "prepared['added_defines']==[]")
    text = text.replace('early-bus-func-r1', 'early-bus-func-r2').replace('early-bus-delivery-r1', 'early-bus-delivery-r2')
    text = replace(text, "assert [r['results']['proof']['answer'] for r in checked['rows']]==['unsat','sat','sat','sat','sat']",
        "assert [r['results']['native']['native_exit'] for r in checked['rows']]==[0,1,1,1,1]\n"
        "        assert checked['rows'][0]['results']['native']['coverage']['checks']==294912\n"
        "        assert (proof/name/'proof.log').read_text().strip()=='unsat'")
    marker = '# Canonical failures remain failures. No standard-suite or physical pass.\n'
    text = replace(text, marker, '''# Real INT/IRET, relocated IVT, SMM/RSM and original save-map witnesses.
physical=load_proof('early-bus-physical-r2/closed.json')
assert physical['passed'] and physical['pins_unchanged'] and not physical['errors']
assert len(physical['rows'])==18 and all(r['paired_v']>0 for r in physical['rows'])
pins.update(load_proof('early-bus-physical-r2/started.json')['pins'])
matched=load_proof('early-bus-matched-inputs-r1/closed.json')
assert matched['regression_check_passed'] and matched['pins_unchanged'] and not matched['errors']
assert len(matched['rows'])==108 and not matched['masks_or_record_normalization']
pins.update(load_proof('early-bus-matched-inputs-r1/started.json')['pins'])
'''+marker)
    text = span(text, '    rationale=', '    generic_gate=',
        "    rationale='Replace zero default plus late translation-authority address mux with early cur_lin default, retaining all six physical overrides and all request/translation/fault/A20 checks. One HDL delta, unchanged 159 defines. Full old-driver simulation assertions, local proof and negative controls, cold real-mode/SMM and system/QEMU A-B checks, exact matched canonical inputs and short CoreMark clocks required. Compare with closed 33.603279680 MHz parent; no gate waiver, route or board acceptance.',\n")
    guarded(text, old)
    a, b = 'host = available()\n', "(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)] == old[old.index(a):old.index(b)]
    outputs['early-bus-synthesis-r1/run.py'] = text

    old = original['decode-bus-clock-r1/run.py']
    text = common(old)
    text = replace(text, str(ROOT/'branch-address-synthesis-r1'), str(ROOT/'decode-bus-synthesis-r1'))
    text = replace(text, '0aaa3d5674f2adbaa99f5a1816a09b68f595cb347bd418ed3f6bb028c92036a6', PARENT_DCP)
    clock_guarded(text, old)
    outputs['early-bus-clock-r1/run.py'] = text

    text = common(original['decode-bus-synthesis-r1/audit_closed.py'])
    for suffix in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(ROOT/('branch-address-'+suffix)), str(ROOT/('decode-bus-'+suffix)))
    text = replace(text, 'f3d9952f0d85d60ce85a85bfec38bb37a939b39a739dc02e6ebde5a6d0297427', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(changes)+'\n')
    text = replace(text, "assert manifest['hardware_defines'][:155]+manifest['hardware_defines'][156:]==old_manifest['hardware_defines']",
                   "assert manifest['hardware_defines']==old_manifest['hardware_defines']")
    text = replace(text, "only_added_define='VEN_X87_MF_STRICT'", 'only_added_define=None')
    text = replace(text, 'one-file DECODE bus transfer and strict waiting-x87 policy', 'one-file early bus transfer')
    text = replace(text, 'Only strict waiting-x87 is added; clocks are unchanged;', 'All definitions and clocks are unchanged;')
    outputs['early-bus-synthesis-r1/audit_closed.py'] = text
    text = common(original['decode-bus-clock-r1/audit_closed.py'])
    outputs['early-bus-clock-r1/audit_closed.py'] = replace(text, '(-2.922)', '(-4.759)')
    outputs['early-bus-clock-r1/audit.tcl'] = original['decode-bus-clock-r1/audit.tcl']
    for name, text in outputs.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return outputs


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    source = root/'early-bus-fpga-r1'
    assert sha(source/'input-manifest.json') == MANIFEST
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256'] == PARENT_MANIFEST and manifest['simulator_sha256'] == MODEL
    assert sha(root/'early-bus-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    changes = {n: sha(source/n) for n in manifest['changed_parent_payloads']}
    for n in changes:
        assert native.recipe.transform((root/'decode-bus-fpga-r1'/n).read_text()) == (source/n).read_text()
    original, pins = {}, {}
    for n, digest in TEMPLATES.items():
        p = root/n
        assert sha(p) == digest
        original[n], pins[str(p)] = p.read_text(), digest
    for p in (Path(__file__), Path(native.__file__), Path(native.recipe.__file__),
              Path(__file__).with_name('prepare_fragment_exact_timing.py'),
              Path(__file__).with_name('prepare_payload_current_synthesis.py'),
              Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(p.resolve())] = sha(p)
    outputs = derive(original, changes)
    receipt = root/'early-bus-timing-prepared.json'
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


if __name__ == '__main__': main()
