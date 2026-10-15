"""Prepare guarded full-core opcode-selector measurements; launch nothing.

Retain the parent's native lifecycle, resource floors and diagnostic mapper.
Do not promote private equivalence checks into canonical or FPGA acceptance.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_prefix_opcode_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

SCRATCH = Path('/home/yukidama/external/tmp').resolve(strict=True)
ROOT = SCRATCH/'ventium-data-size.v2HaTO2X'
MANIFEST = '3c843461da525a0ac78303ba67900815cb8a0a4be0787e99ead9d9299c2a8788'
MODEL = '977e63611f3addef40bdf60ccab402d949e82416c715a6551859a86d6451517d'
PARENT_MANIFEST = '9e53127a928b0044465174583cb7ed87abc8da1d7644056054d3ceeeb5688bbb'
PARENT_DCP = '5c0ee4195b9331cf7eb31b022b86753feecd892cd3cff78cc1448c717b4b6557'
CHANGES = {'ventium/rtl/core/decode_stages.sv':
           '91feb7e219d2dbbe131825d6b55889392e7924c814915eba5558b0c8a7458f5c'}
TEMPLATES = {
    'prefix-payload-synthesis-r1/run.py': '1a7334a35898a0752c0b02c0c6a1c743d15c9daac18054f567cba1bf0469f949',
    'prefix-payload-synthesis-r1/audit_closed.py': '836279ac216094ed57390fabfaef955d33a2839ab48b560d4b1db2557fc8b6d7',
    'prefix-payload-clock-r1/run.py': '048d633e4833a7fe86c49911077a0d0e90dab2524c261a47881dc1ce9587745c',
    'prefix-payload-clock-r1/audit_closed.py': 'df520086d20eba834e32b0579f256dbd06bb39eeee2236e005b120d27f363355',
    'prefix-payload-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
LEAF_PROOF = '''leaf=load_proof('prefix-opcode-leaf-r2/closed.json')
assert sha(proof/'prefix-opcode-leaf-r2/closed.json')=='02c30279130b74bcf991a3b4521da074f17887c2d0f4866f2ced0b922f8dfac2'
assert leaf['passed'] and leaf['pins_unchanged'] and not leaf['errors']
assert leaf['checks']==2752512 and leaf['outputs']==122
assert not leaf['full_core'] and not leaf['hardware_acceptance'] and not leaf['standard_suite']
assert leaf['definitions']==json.loads((core/'build-started.json').read_text())['definitions']
assert [r['exit'] for r in leaf['native']]==[0,0,1,1]
assert all(r['affinity']==[14] for r in leaf['native'])
pins.update(leaf['pins'])
for row in leaf['native']:
    assert sha(row['log'])==row['sha256']
    pins[row['log']]=row['sha256']
path=proof/'prefix-opcode-leaf-r2/obj/test'
assert sha(path)==leaf['model_sha256']
pins[str(path)]=leaf['model_sha256']
# Historical parent boundary failures remain open. This is NOT a candidate
# finite-CS rerun or an acceptance pass, and never authorizes deployment.
boundary=load_proof('prefix-payload-boundary-r1/closed.json')
assert sha(proof/'prefix-payload-boundary-r1/closed.json')=='cae9437414fa4e47d43ea0081129838b5a3d085030ffbf0e77735a55628924a3'
assert not boundary['passed'] and boundary['errors']
'''


def common(text):
    return (text.replace('prefix-payload-', 'prefix-opcode-')
            .replace('prefix_payload_timing', 'prefix_opcode_timing')
            .replace('build_prefix_payload_soc', 'build_prefix_opcode_soc')
            .replace('prefix-opcode-system-r2', 'prefix-opcode-system-r1')
            .replace('ventium-prefix-opcode-system-oct14-r2', 'ventium-prefix-opcode-system-oct15-r1')
            .replace('ventium-prefix-opcode-synth-oct14-r1', 'ventium-prefix-opcode-synth-oct15-r1')
            .replace('ventium-prefix-opcode-clock-oct14-r1', 'ventium-prefix-opcode-clock-oct15-r1')
            .replace('baseline_gameplay_ipc=0.51186266,baseline_window=[1700065237,1800065237]',
                     'baseline_gameplay_ipc=0.50520554,baseline_window=[5600065237,5700065237]'))


def derive(original):
    outputs = {}
    old = original['prefix-payload-synthesis-r1/run.py']
    text = common(old)
    text = replace(text,
        'e16799c98385d94ddae7d4cb7296a56cf207ec0f3b43110058a0d03d841c02e8',
        '1f80a208437fd359c5c8dd078f68f1a632fa8df539043a0c646fb5d88f967c92')
    text = replace(text,
        'Measure equivalent register-prefix memory-payload isolation; no route or deployment.',
        'Measure parallel prefix endpoint opcode selection; no route or deployment.')
    text = span(text, "leaf=load_proof('prefix-opcode-leaf-r1/closed.json')",
                "system=load_proof('prefix-opcode-system-r1/closed.json')", LEAF_PROOF)
    text = replace(text,
        'e7707265d23fdbf8b780a9324b5a6d3ebed439beeb2f23748fa34f38852a374f',
        '9e7be15bcf2f3771d82109bfafd398f2fe6e9ccf494f61a5e33a58c573511bc7')
    text = span(text, '    rationale=', '    generic_gate=',
        "    rationale='Select opcode bytes directly from the parallel prefix endpoint instead of serial count encoding and variable muxes. Exactly one decoder source; no semantic opcode, state, latency, define, cache or transport change. Target the measured 36.591166892 MHz parent; the isolated real decoder byte path improved 8.95 percent, with area cost. Actual-decoder miter/mutants, full architectural replay, system/fetch/fault checks and short CoreMark CRC clocks are retained. Canonical and historical finite-CS failures remain open. This is diagnostic synthesis, not promotion, routing or hardware acceptance.',\n")
    guarded(text, old)
    first, last = 'host = available()\n', "(root/'once').mkdir()"
    assert text[text.index(first):text.index(last)] == old[old.index(first):old.index(last)]
    outputs['prefix-opcode-synthesis-r1/run.py'] = text

    old = original['prefix-payload-clock-r1/run.py']
    text = common(old)
    text = replace(text, str(ROOT/'fast-segment-synthesis-r2'), str(ROOT/'prefix-payload-synthesis-r1'))
    text = replace(text, '8d41c9b7cbeb543c9d72b253e53ca15de204200229d4517efe73b2d6ca7176b0', PARENT_DCP)
    clock_guarded(text, old)
    outputs['prefix-opcode-clock-r1/run.py'] = text

    text = common(original['prefix-payload-synthesis-r1/audit_closed.py'])
    for before, after in (('fast-segment-synthesis-r2', 'prefix-payload-synthesis-r1'),
                          ('fast-segment-fpga-r1', 'prefix-payload-fpga-r1')):
        text = replace(text, str(ROOT/before), str(ROOT/after))
    text = replace(text, 'd4122ecbed950b845654bec8060fa83b96213f07b373b002604704cea06b6f7e', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    text = replace(text, 'one-include prefix-payload transfer', 'one-file prefix-opcode transfer')
    outputs['prefix-opcode-synthesis-r1/audit_closed.py'] = text
    text = common(original['prefix-payload-clock-r1/audit_closed.py'])
    outputs['prefix-opcode-clock-r1/audit_closed.py'] = replace(text, '(-3.189)', '(-2.329)')
    outputs['prefix-opcode-clock-r1/audit.tcl'] = original['prefix-payload-clock-r1/audit.tcl']
    for name, text in outputs.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    root = parser.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == SCRATCH
    source = root/'prefix-opcode-fpga-r1'
    assert sha(source/'input-manifest.json') == MANIFEST
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    assert set(manifest['changed_parent_payloads']) == set(CHANGES)
    assert sha(root/'prefix-opcode-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    for name, digest in CHANGES.items():
        assert sha(source/name) == digest
        assert native.transform(name.removeprefix('ventium/'),
            (root/'prefix-payload-fpga-r1'/name).read_text()) == (source/name).read_text()
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        path = root/name
        assert sha(path) == digest
        original[name] = path.read_text()
        pins[str(path)] = digest
    for path in (Path(__file__), Path(native.__file__), native.original, Path(native.recipe.__file__),
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py'),
                 Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(path.resolve())] = sha(path)
    outputs = derive(original)
    receipt = root/'prefix-opcode-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in outputs)
    for name, text in outputs.items():
        path = root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as stream: stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n): sha(root/n) for n in outputs},
            source_manifest_sha256=MANIFEST, model_sha256=MODEL, canonical_gate_passed=False,
            standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None), stream, indent=2)
    print('Guarded prefix-opcode controllers prepared; nothing launched.', flush=True)


if __name__ == '__main__': main()
