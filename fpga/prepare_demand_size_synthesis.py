"""Prepare one source-matched demand-width timing experiment; launch nothing.

The prior native lifetime, exclusive ownership and resource controls must be
byte-identical. Only model/source identities and leaf evidence differ.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_demand_size_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
PARENT_MANIFEST = '9ec9a00dc8a73884074f6ea5e01ba9925f3725bc90425693b974d38fc061e5e7'
PARENT_DCP = '77a756d780ea8c67f6a93572e52fa1cbb7ad9dcc2d066455fa1106494ec6a1a2'
TEMPLATES = {
    'early-bus-synthesis-r1/run.py': '1bf50759b253e60447325edc2f840a324dfb456986eb856eab5df68130bef377',
    'early-bus-synthesis-r1/audit_closed.py': 'b622e5b44e19b89eba804feb79b6f3199b60bacab1dc352f3fa002c5745f6908',
    'early-bus-clock-r1/run.py': '8227cd29337c2df0b5b4be9d03dcc8f26d7e81f4c11bdbe428ea6b698934c5c2',
    'early-bus-clock-r1/audit_closed.py': '6fd2c542ddccc897973e8ab8c0d73a3f38a1802ff86f4615f4af20664990f766',
    'early-bus-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def common(text):
    return (text.replace('early-bus-', 'demand-size-')
        .replace('early_bus_payload_timing', 'demand_size_payload_timing')
        .replace('build_early_bus_soc', 'build_demand_size_soc')
        .replace('demand-size-func-r2', 'demand-size-func-r1')
        .replace('demand-size-delivery-r2', 'demand-size-delivery-r1')
        .replace('demand-size-physical-r2', 'demand-size-physical-r1'))


def derive(original, changes):
    assert set(changes) == {'ventium/'+native.recipe.FILE}
    outputs = {}
    old = original['early-bus-synthesis-r1/run.py']
    text = common(old)
    text = replace(text, 'Measure early bus payload; same strict x87 policy, no route or deployment.',
                   'Measure request-independent demand-width payload; no route or deployment.')
    text = span(text, "        assert len(checked['rows'])==5 and not checked['whole_core']\n",
                "        pins.update(checked['artifacts'])\n", '''        assert not checked['whole_core'] and len(checked['rows'])==8
        import build_demand_size_core as demand_builder
        pins.update(demand_builder.check_leaf(proof/name))
        pins[str(Path(demand_builder.__file__))]=sha(demand_builder.__file__)
''')
    text = span(text, '    rationale=', '    generic_gate=',
        "    rationale='Remove request authorization only from demand-width payload calculation. Preserve exact issued extent, page clip and all request, translation, fault and commit conditions. Both leaf profiles and negative controls, old-width/inactive-authority assertions, complete cold boundary/system/x87/SMM and matched-input A-B checks plus short CoreMark controls required. Compare with the closed 34.049507985 MHz unplaced parent; not a gate waiver, route or physical acceptance.',\n")
    guarded(text, old)
    a, b = 'host = available()\n', "(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)] == old[old.index(a):old.index(b)]
    outputs['demand-size-synthesis-r1/run.py'] = text

    old = original['early-bus-clock-r1/run.py']
    text = common(old)
    text = replace(text, str(ROOT/'decode-bus-synthesis-r1'), str(ROOT/'early-bus-synthesis-r1'))
    text = replace(text, 'd8365bb3948afaf521abd8a3c9d282e5a10ae9a50e456e678d75a86eab671fae', PARENT_DCP)
    clock_guarded(text, old)
    outputs['demand-size-clock-r1/run.py'] = text

    text = common(original['early-bus-synthesis-r1/audit_closed.py'])
    for suffix in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(ROOT/('decode-bus-'+suffix)), str(ROOT/('early-bus-'+suffix)))
    text = replace(text, '36908a9d96c4ddca51d143f634acacc85c067bfeb1aaf24833a9eda99fb6a7dc', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(changes)+'\n')
    text = replace(text, 'one-file early bus transfer', 'one-file demand-width transfer')
    outputs['demand-size-synthesis-r1/audit_closed.py'] = text
    text = common(original['early-bus-clock-r1/audit_closed.py'])
    outputs['demand-size-clock-r1/audit_closed.py'] = replace(text, '(-4.759)', '(-4.369)')
    outputs['demand-size-clock-r1/audit.tcl'] = original['early-bus-clock-r1/audit.tcl']
    for name, text in outputs.items():
        if name.endswith('.py'):
            ast.parse(text, filename=name)
    return outputs


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    source = root/'demand-size-fpga-r1'
    manifest = json.loads((source/'input-manifest.json').read_text())
    freeze = json.loads((source/'freeze-receipt.json').read_text())
    manifest_sha = sha(source/'input-manifest.json')
    assert freeze['manifest_sha256'] == manifest_sha and freeze['source_contract_passed']
    assert manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    assert sha(root/'early-bus-fpga-r1/input-manifest.json') == PARENT_MANIFEST
    model = sha(root/'demand-size-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert manifest['simulator_sha256'] == model
    built = native.load(root/'demand-size-soc-r1/build-closed.json')
    assert built['passed'] and built['inputs_unchanged'] and built['binary_sha256'] == model
    changes = {n: sha(source/n) for n in manifest['changed_parent_payloads']}
    for n in changes:
        assert native.recipe.transform((root/'early-bus-fpga-r1'/n).read_text()) == (source/n).read_text()
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
    receipt = root/'demand-size-timing-prepared.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in outputs)
    for n, text in outputs.items():
        p = root/n
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open('x') as f:
            f.write(text)
    with receipt.open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n): sha(root/n) for n in outputs},
            source_manifest_sha256=manifest_sha, model_sha256=model, canonical_gate_passed=False,
            standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None), f, indent=2)
    print('Guarded synthesis/clock controllers prepared; neither launched.', flush=True)


if __name__ == '__main__':
    main()
