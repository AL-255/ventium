"""Prepare guarded matched synthesis of the tested fetch/pair composition.

Preserve the parent's native process lifecycle and RAM/swap/disk guards. The
two rejected constituent timing results are not inherited as combined timing.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_fetch_pair_next_soc as native
import prepare_pair_next_disjoint_synthesis as prior
from prepare_fragment_exact_timing import replace, sha, span

ROOT, templates = prior.ROOT, prior.templates
MANIFEST = 'f4359c33b0711cc2182d3835cacd92972b4c5329c56ee93f20babfe9e21624e9'
MODEL = '5a50175cd6daec6079b2d2cd94fd4857d09d09d99a2b41ea5ad4a52c8d2570d9'
AUDIT = '9441cfb60415fa1dfc3f5d83a40fc1a981fb3a3790627f1653fd7d1c5ddfc73a'

# Re-exercise all whole-core cases on the composition. Only the unchanged
# leaf transformations' proofs are deliberately reused and labelled as such.
PROOF = prior.PROOF.replace('pair-next-disjoint-', 'fetch-pair-next-').replace(
    'fetch-pair-next-leaf-r6', 'pair-next-disjoint-leaf-r6') + '''
fetch_leaf=load_proof('fetch-fragment-leaf-r5/closed.json')
assert sha(proof/'fetch-fragment-leaf-r5/closed.json')=='c521a2ef21d288398b6b70b3015a284b5e54615b4232ff366ba2fc1fcd07c11e'
assert fetch_leaf['passed'] and fetch_leaf['pins_unchanged'] and not fetch_leaf['errors']
assert len(fetch_leaf['native'])==12 and len(fetch_leaf['profiles'])==2
pins.update(fetch_leaf['pins'])
for folder_name,count in (('fetch-pair-next-fetch-r1',88),
                          ('fetch-pair-next-envfault-r1',44),
                          ('fetch-pair-next-finitecs-r2',8)):
    folder=proof/folder_name
    checked=load_proof(str(folder.relative_to(proof)/'closed.json'))
    started=load_proof(str(folder.relative_to(proof)/'started.json'))
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert len(checked['rows'])==count
    pins.update(started['pins'])
    for path in folder.rglob('*'):
        if path.is_file():pins[str(path)]=sha(path)
    if folder_name.endswith('fetch-r1'):
        assert checked['candidate_records']==21832 and checked['paired_v']==4968
        assert checked['probe_witnesses']==44
    elif folder_name.endswith('envfault-r1'):
        assert started['model']==str(core/'obj/tb_ventium')
        assert all(r['passed'] and len(r['rows'])==2 for r in checked['rows'])
    else:
        assert started['models']['candidate']==str(core/'obj/tb_ventium')
        assert not checked['original_gate_passed'] and not checked['qemu_differential']
        assert all(r['passed'] and len(r['rows'])==12 for r in checked['rows'])
'''


def derive(original, changes):
    outputs = prior.derive(original, changes)
    result = {}
    for name, text in outputs.items():
        if name.endswith('synthesis-r2/run.py'):
            text = replace(text, prior.PROOF, '__COMPOSED_PROOF__\n')
        for old, new in (
            ('pair-next-disjoint-synthesis-r2', 'fetch-pair-next-synthesis-r1'),
            ('pair-next-disjoint-clock-r2', 'fetch-pair-next-clock-r1'),
            ('pair-next-disjoint-timing-prepared-r2.json', 'fetch-pair-next-timing-prepared-r1.json'),
            ('pair-next-disjoint-', 'fetch-pair-next-'),
            ('pair_next_disjoint_timing', 'fetch_pair_next_timing'),
            ('build_pair_next_disjoint_soc', 'build_fetch_pair_next_soc'),
            ('fetch-pair-next-synth-oct15-r2', 'fetch-pair-next-synth-oct15-r1'),
            ('fetch-pair-next-clock-oct15-r2', 'fetch-pair-next-clock-oct15-r1'),
            (prior.AUDIT, AUDIT),
            ('three-file pair/next arbitration transfer', 'four-file fetch/pair composition transfer'),
        ):
            name, text = name.replace(old, new), text.replace(old, new)
        if name.endswith('synthesis-r1/run.py'):
            text = replace(text, '__COMPOSED_PROOF__\n', PROOF)
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Compose the exact fetch extent and pair/next cofactors, addressing each constituent netlist remaining critical cone. Four source deltas, unchanged cache/transport/clock/features. Fresh combined whole-core, fault and short cold-PC controls are required. Neither standalone timing result implies combined timing. Compare against the retained 36.591166892 MHz parent with the same logic-only mapper. Canonical remains FAIL; no route, full-suite or physical acceptance inherited.',\n")
            text = replace(text,
                "generic_gate='FUNC 108/108 with existing masks; cycle/fault gates remain red; CPU lint only, not full SoC or suite'",
                "generic_gate='Authenticated private replay 108/108 (105 unmasked), not a fresh canonical pass; canonical 7 PASS/101 FAIL, exit 2; finite-CS oracle discrepancy open; CPU lint only, not full SoC or suite'")
            prior.guarded(text, original['prefix-payload-synthesis-r1/run.py'])
        if name.endswith('.py'):
            ast.parse(text, filename=name)
        result[name] = text
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    root = parser.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == ROOT.parent
    source = root/'fetch-pair-next-fpga-r1'
    assert sha(source/'input-manifest.json') == MANIFEST
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256'] == prior.PARENT_MANIFEST
    assert sha(root/'fetch-pair-next-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    changes = {name: sha(source/name) for name in manifest['changed_parent_payloads']}
    assert set(changes) == {'ventium/'+n for n in native.CHANGES}
    for name in changes:
        assert native.transform(name.removeprefix('ventium/'),
            (root/'prefix-payload-fpga-r1'/name).read_text()) == (source/name).read_text()
    original, pins = {}, {}
    for name, digest in templates.TEMPLATES.items():
        path = root/name
        assert sha(path) == digest
        original[name] = path.read_text()
        pins[str(path)] = digest
    for module in (native, native.prior, native.previous, native.recipe, native.recipe.fetch,
                   native.recipe.pair, prior, templates):
        path = Path(module.__file__).resolve()
        pins[str(path)] = sha(path)
    for path in (Path(__file__), native.original,
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py'),
                 Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(path.resolve())] = sha(path)
    outputs = derive(original, changes)
    receipt = root/'fetch-pair-next-timing-prepared-r1.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in outputs)
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
    print('Guarded composition controllers prepared; nothing launched.', flush=True)


if __name__ == '__main__':
    main()
