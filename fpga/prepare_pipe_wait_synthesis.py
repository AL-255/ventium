"""Prepare one matched wait-cofactor timing experiment; launch nothing.

Keep the prior native lifetime, exclusive owner and resource controls byte
identical. Require all cold correctness evidence and unchanged short CRC
controls. Canonical failures remain failures; no route or deployment follows.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_pipe_wait_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
PARENT_MANIFEST = 'd35a4b77598c979affbe91bb3e245587e118d0244e271872527b9555115f5315'
PARENT_DCP = '5ebc7472c4130f7939e0673d78df53a5fee378bc7d7da2adbd4d740bd471cfd5'
TEMPLATES = {
    'demand-size-synthesis-r1/run.py': 'be12fa79be24631f75657928fc4a356a5ca0cdc59763228fecb1e179ad68a676',
    'demand-size-synthesis-r1/audit_closed.py': 'c7dd3edc94d6e431e9f504dc64d1cb3c188182c10c28d744c52aadf2c23b77b9',
    'demand-size-clock-r2/run.py': '54b32b929e741635ffa5e50e65c6fbeeb0b9c44329752e6fb23a7c94441222a1',
    'demand-size-clock-r2/audit_closed.py': 'b57f407d30741f3f7387f46b69d9cc33e161d0cdd550776a2621e44a9ff0b681',
    'demand-size-clock-r2/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def common(text):
    return (text.replace('demand-size-', 'pipe-wait-')
        .replace('demand_size_payload_timing', 'pipe_wait_read_ack_timing')
        .replace('build_demand_size_soc', 'build_pipe_wait_soc')
        .replace('ventium-pipe-wait-clock-oct15-r2.service', 'ventium-pipe-wait-clock-oct15-r1.service'))


def derive(original, changes):
    assert set(changes) == {'ventium/'+native.recipe.FILE}
    outputs = {}
    old = original['demand-size-synthesis-r1/run.py']
    text = common(old)
    text = replace(text, 'Measure request-independent demand-width payload; no route or deployment.',
                   'Measure read-owner pipeline wait cofactor; no route or deployment.')
    text = replace(text, "assert not checked['whole_core'] and len(checked['rows'])==8",
                   "assert not checked['whole_core'] and len(checked['rows'])==10")
    text = replace(text, 'import build_demand_size_core as demand_builder',
                   'import build_pipe_wait_read_ack_core as wait_builder')
    text = text.replace('demand_builder', 'wait_builder')
    marker = "verify=load_proof('pipe-wait-core-r1/verify-closed.json')"
    text = replace(text, marker, 'pins.update(native.extended_evidence(proof, core))\n'+marker)
    text = span(text, '    rationale=', '    generic_gate=',
        "    rationale='Separate read and write pipeline waits using the existing fragment-qualified read ACK. Preserve mixed U-load/V-store acceptance and every request/fault/commit rule. Require source-linked equality in both profiles, eight failing negative controls, cold mixed/held/store/system/x87/SMM checks, complete identical-input A-B streams and short CoreMark CRC/tick controls. Compare with the closed 35.875726483 MHz unplaced parent; no canonical waiver, route or physical acceptance.',\n")
    guarded(text, old)
    a, b = 'host = available()\n', "(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)] == old[old.index(a):old.index(b)]
    outputs['pipe-wait-synthesis-r1/run.py'] = text

    old = original['demand-size-clock-r2/run.py']
    text = common(old)
    text = replace(text, str(ROOT/'early-bus-synthesis-r1'), str(ROOT/'demand-size-synthesis-r1'))
    text = replace(text, '77a756d780ea8c67f6a93572e52fa1cbb7ad9dcc2d066455fa1106494ec6a1a2', PARENT_DCP)
    clock_guarded(text, old)
    outputs['pipe-wait-clock-r1/run.py'] = text

    text = common(original['demand-size-synthesis-r1/audit_closed.py'])
    for suffix in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(ROOT/('early-bus-'+suffix)), str(ROOT/('demand-size-'+suffix)))
    text = replace(text, '9ec9a00dc8a73884074f6ea5e01ba9925f3725bc90425693b974d38fc061e5e7', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(changes)+'\n')
    text = replace(text, 'one-file demand-width transfer', 'one-file pipeline wait transfer')
    outputs['pipe-wait-synthesis-r1/audit_closed.py'] = text
    text = common(original['demand-size-clock-r2/audit_closed.py'])
    outputs['pipe-wait-clock-r1/audit_closed.py'] = replace(text, '(-4.369)', '(-2.874)')
    outputs['pipe-wait-clock-r1/audit.tcl'] = original['demand-size-clock-r2/audit.tcl']
    for name, text in outputs.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return outputs


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    source = root/'pipe-wait-fpga-r1'
    manifest = json.loads((source/'input-manifest.json').read_text())
    freeze = json.loads((source/'freeze-receipt.json').read_text())
    manifest_sha = sha(source/'input-manifest.json')
    assert freeze['manifest_sha256'] == manifest_sha and freeze['source_contract_passed']
    assert manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    assert sha(root/'demand-size-fpga-r1/input-manifest.json') == PARENT_MANIFEST
    model = sha(root/'pipe-wait-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert manifest['simulator_sha256'] == model
    built = native.load(root/'pipe-wait-soc-r1/build-closed.json')
    assert built['passed'] and built['inputs_unchanged'] and built['binary_sha256'] == model
    changes = {n: sha(source/n) for n in manifest['changed_parent_payloads']}
    for n in changes:
        assert native.recipe.transform((root/'demand-size-fpga-r1'/n).read_text()) == (source/n).read_text()
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
    receipt = root/'pipe-wait-timing-prepared.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in outputs)
    for n, text in outputs.items():
        p = root/n
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open('x') as f: f.write(text)
    with receipt.open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n):sha(root/n) for n in outputs},
            source_manifest_sha256=manifest_sha, model_sha256=model, canonical_gate_passed=False,
            standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None), f, indent=2)
    print('Matched guarded synthesis/clock controllers prepared; neither launched.', flush=True)


if __name__ == '__main__':
    main()
