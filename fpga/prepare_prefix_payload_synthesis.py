"""Prepare guarded, source-matched prefix-payload synthesis; launch nothing.

Preserve the closed parent's entire native lifecycle and resource admission.
Only candidate/proof identities and the immediate-parent comparison change.
No route, bitstream, hardware or standard-suite acceptance is authorized here.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_prefix_payload_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

SCRATCH = Path('/home/yukidama/external/tmp').resolve(strict=True)
ROOT = SCRATCH/'ventium-data-size.v2HaTO2X'
MANIFEST = '9e53127a928b0044465174583cb7ed87abc8da1d7644056054d3ceeeb5688bbb'
MODEL = '5eee4d74d729663ad6af4abaa3f0fdbd5cc59937a36945ca81ff46e33b891ce9'
PARENT_MANIFEST = 'd4122ecbed950b845654bec8060fa83b96213f07b373b002604704cea06b6f7e'
PARENT_DCP = '8d41c9b7cbeb543c9d72b253e53ca15de204200229d4517efe73b2d6ca7176b0'
CHANGES = {'ventium/rtl/core/core_prefix66_decode.svh':
           '6a29557a726b5536f2655b4d5459d43e157f22579d365b641d9776d507ac4aa5'}
TEMPLATES = {
    'fast-segment-synthesis-r2/run.py': 'fbc7adf7c2f33968f8e1267a230b36ba43516070fb79eac515640d2d90cd16f3',
    'fast-segment-synthesis-r2/audit_closed.py': '9f2d6becd0b3c7aefb9b3c1f315ab3fb32bc9f77c173843c772b51774e505ffa',
    'fast-segment-clock-r2/run.py': 'c3229f585bf9c65b8d0972687f3a6ff157255a55b99ae7dc71b95d42bf540a2f',
    'fast-segment-clock-r2/audit_closed.py': '4ec9fad0fb676c32752f0e83c2615d9896c928c6a05b252d3c48dab6c169796b',
    'fast-segment-clock-r2/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
LEAF_PROOF = '''leaf=load_proof('prefix-payload-leaf-r1/closed.json')
assert sha(proof/'prefix-payload-leaf-r1/closed.json')=='96d075884581ee10dc9b36845f673bef8c68eb8c72bf55c533684a667495ebcb'
assert leaf['passed'] and leaf['pins_unchanged'] and not leaf['errors']
assert [r['name'] for r in leaf['profiles']]==['minimal','candidate']
assert all(r['checks']==17532577 and r['rejected_mutants']==3 for r in leaf['profiles'])
assert leaf['profiles'][1]['definitions']==json.loads((core/'build-started.json').read_text())['definitions']
assert len(leaf['native'])==10 and [r['exit'] for r in leaf['native']]==[0,0,1,1,1]*2
assert all(r['affinity']==[14] for r in leaf['native'])
pins.update(leaf['input_pins'])
for row in leaf['native']:
    assert sha(row['log'])==row['log_sha256']
    pins[row['log']]=row['log_sha256']
for row in leaf['profiles']:
    path=proof/'prefix-payload-leaf-r1'/row['name']/'obj/test'
    assert sha(path)==row['model_sha256']
    pins[str(path)]=row['model_sha256']
# Preserve the separate unresolved boundary gate; this experiment does not
# promote RTL, change its oracle, waive its failures or authorize deployment.
boundary=load_proof('prefix-payload-boundary-r1/closed.json')
assert sha(proof/'prefix-payload-boundary-r1/closed.json')=='cae9437414fa4e47d43ea0081129838b5a3d085030ffbf0e77735a55628924a3'
assert not boundary['passed'] and boundary['errors']
'''


def common(text):
    text = (text.replace('fast-segment-', 'prefix-payload-')
            .replace('fast_segment_timing', 'prefix_payload_timing')
            .replace('build_fast_segment_soc', 'build_prefix_payload_soc'))
    for before, after in (
        ('prefix-payload-synthesis-r2', 'prefix-payload-synthesis-r1'),
        ('prefix-payload-clock-r2', 'prefix-payload-clock-r1'),
        ('ventium-prefix-payload-synth-oct14-r2', 'ventium-prefix-payload-synth-oct14-r1'),
        ('ventium-prefix-payload-clock-oct14-r2', 'ventium-prefix-payload-clock-oct14-r1'),
        ('prefix-payload-timing-prepared-r2.json', 'prefix-payload-timing-prepared.json')):
        text = text.replace(before, after)
    return text


def baseline(text):
    return replace(text,
        'baseline_gameplay_ipc=0.47330821,baseline_window=[1500065237,1600065237]',
        'baseline_gameplay_ipc=0.51186266,baseline_window=[1700065237,1800065237]')


def derive(original):
    outputs = {}
    old = original['fast-segment-synthesis-r2/run.py']
    text = baseline(common(old))
    text = replace(text,
        'efcc3318f5c3af9a5926da23a206af9e06f9edbe5c321769564efff4c0e37232',
        'e16799c98385d94ddae7d4cb7296a56cf207ec0f3b43110058a0d03d841c02e8')
    text = replace(text,
        'Measure equivalent parallel fast-memory segment admission; no route or deployment.',
        'Measure equivalent register-prefix memory-payload isolation; no route or deployment.')
    text = span(text, "leaf=load_proof('prefix-payload-leaf-r1/closed.json')",
                "system=load_proof('prefix-payload-system-r2/closed.json')", LEAF_PROOF)
    text = replace(text,
        'a30de9aeb360b8c276037fa561bd2c147f996eceef313a62071afcb439dffcf9',
        'e7707265d23fdbf8b780a9324b5a6d3ebed439beeb2f23748fa34f38852a374f')
    text = span(text, '    rationale=', '    generic_gate=',
        "    rationale='Remove late register-prefix admission/length from memory-address metadata using the checked raw-decoder cofactor. Exactly one include, no added cycle/state/define or cache change. Target the measured 35.474830608 MHz EIP-to-ESP path. Actual-decoder positive/negative checks, complete architectural replay, system/fetch/fault controls and unchanged short CRC clocks are retained. Canonical and prefix-boundary gates remain failed; no promotion, full-suite or physical acceptance is inferred.',\n")
    guarded(text, old)
    first, last = 'host = available()\n', "(root/'once').mkdir()"
    assert text[text.index(first):text.index(last)] == old[old.index(first):old.index(last)]
    outputs['prefix-payload-synthesis-r1/run.py'] = text

    old = original['fast-segment-clock-r2/run.py']
    text = baseline(common(old))
    text = replace(text, str(ROOT/'way-banked-synthesis-r1'), str(ROOT/'fast-segment-synthesis-r2'))
    text = replace(text, '8aaea5943daa2337ee404c466ec20ad95efb2198c6f4d79a22547580f6bfa92c', PARENT_DCP)
    clock_guarded(text, old)
    outputs['prefix-payload-clock-r1/run.py'] = text

    text = common(original['fast-segment-synthesis-r2/audit_closed.py'])
    for before, after in (('way-banked-synthesis-r1','fast-segment-synthesis-r2'),
                          ('way-banked-fpga-r1','fast-segment-fpga-r1')):
        text = replace(text, str(ROOT/before), str(ROOT/after))
    text = replace(text, '8f4cf7b06c4368cf888300300513a2835fe7bd678e192b48839bebdb00fe1523', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    text = replace(text, 'one-file segment-admission transfer', 'one-include prefix-payload transfer')
    outputs['prefix-payload-synthesis-r1/audit_closed.py'] = text
    text = common(original['fast-segment-clock-r2/audit_closed.py'])
    outputs['prefix-payload-clock-r1/audit_closed.py'] = replace(text, '(-3.989)', '(-3.189)')
    outputs['prefix-payload-clock-r1/audit.tcl'] = original['fast-segment-clock-r2/audit.tcl']
    for name, text in outputs.items():
        if name.endswith('.py'):
            ast.parse(text, filename=name)
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    root = parser.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == SCRATCH
    source = root/'prefix-payload-fpga-r1'
    assert sha(source/'input-manifest.json') == MANIFEST
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    assert set(manifest['changed_parent_payloads']) == set(CHANGES)
    assert sha(root/'prefix-payload-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    for name, digest in CHANGES.items():
        assert sha(source/name) == digest
        assert native.transform(name.removeprefix('ventium/'),
            (root/'fast-segment-fpga-r1'/name).read_text()) == (source/name).read_text()
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        path = root/name
        assert sha(path) == digest
        original[name] = path.read_text()
        pins[str(path)] = digest
    for path in (Path(__file__), Path(native.__file__), native.original, Path(native.recipe.__file__),
                 native.DECODER_SOURCE, Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py'),
                 Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(path.resolve())] = sha(path)
    outputs = derive(original)
    receipt = root/'prefix-payload-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in outputs)
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
    print('Guarded prefix-payload controllers prepared; nothing launched.', flush=True)


if __name__ == '__main__':
    main()
