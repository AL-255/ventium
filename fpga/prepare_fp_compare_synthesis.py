"""Prepare matched next-tag/FP-classifier timing; preserve all resource guards.

No implementation, programming, acceptance or Fmax improvement is implied.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_fp_compare_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

SCRATCH = Path('/home/yukidama/external/tmp').resolve(strict=True)
ROOT = SCRATCH / 'ventium-data-size.v2HaTO2X'
MANIFEST = '296ff7367ef6af0324c47a09615f09f2c02a700a3de411efc617f598c03c001b'
MODEL = '81edc510dab23425c3935e68b4ac9b5c0d84620e2df9f99e47a0a162f1c8f76a'
PARENT_MANIFEST = '09160fa65d1b67dcfd9bc263715c5b73475c04410991a3941e651f3eb59fa7c8'
PARENT_DCP = '4df9848c06b6423762546bbe6894ecdaba554446f020cd0f24ebd25814df6c14'
CHANGES = {
    'ventium/fp_shared/ven_fp_top.sv': '8f7749836fd2f7c744c450eecc63d3539baf447998a3e00939577cef1705b7e2',
    'ventium/rtl/mem/ven_l1d.sv': '9b888b991ffc38034899f3c9e98bc1e04f9d37268aaba57cf13e1c0495428311',
}
TEMPLATES = {
    'window-current-synthesis-r2/run.py': '54a60cadb74fe63bd565e40695c3fff55e40bccc1e6093001f45f3f1e83f9650',
    'window-current-synthesis-r2/audit_closed.py': 'f84381174adf1a3e78143bb8891665ce1b321953456317dda66a24c30828dc43',
    'window-current-clock-r2/run.py': '439cbcb448503831b9957a7623727fd88fdee54838d61afa9afc5bcce04726e9',
    'window-current-clock-r2/audit_closed.py': '799d77a102953e13d11b870c03b9049946ba3cb76a2bfc0baa24c042cd5d0aa5',
    'window-current-clock-r2/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def common(text):
    # Same candidate-relative identities in the closed R2 controllers.
    text = text.replace('window-current-', 'fp-compare-')
    text = text.replace('window_current_timing', 'fp_compare_timing')
    text = text.replace('build_window_current_soc', 'build_fp_compare_soc')
    text = text.replace('-oct13-r2.service', '-oct14-r1.service')
    text = text.replace('fp-compare-synthesis-r2', 'fp-compare-synthesis-r1')
    return text


def baseline(text):
    text = replace(text, 'baseline_gameplay_ipc=0.51030715,baseline_window=[1200065237,1300065237]',
        'baseline_gameplay_ipc=0.5048994,baseline_window=[800065237,900065237]')
    return replace(text, "baseline_model='2b4d7a48',older_bfb_longer_ipc=0.5002129964444444",
        "baseline_model='c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd'")


def derive(original):
    outputs = {}
    old = original['window-current-synthesis-r2/run.py']
    text = baseline(common(old))
    text = replace(text, 'fp-compare-env-fault-r2', 'fp-compare-env-fault-r1', 3)
    text = replace(text, '1dd4b7175a442465dac426b026255b283acfd9d985bda1d9e7893b5872cddf28',
        '20ec2c93635ad2548b1977e30065e64f910a3630f545385e9fcc2e48bdf36732')
    text = replace(text, 'Measure the source-matched saved-window current-tag cofactor; no route or deployment.',
        'Measure parallel next-line tags and direct FP invalid classification; no route or deployment.')
    text = span(text, '    rationale=', '    generic_gate=',
        "    rationale='Target the measured FPstatus.B and L1-valid paths of the 33.028371371 MHz current-tag parent. Compare next-line tags for current and prime addresses in parallel, selecting the Boolean result; classify FP compare invalid directly from source encoding without integer normalization. Exactly two RTL files, no new cycles, definitions, clocks, timing exceptions or guest patches. UV-fast/full P5/single-fill/posted-16 retained. Area and Fmax must be measured; canonical/full-suite/physical acceptance remain open.',\n")
    guarded(text, old)
    # Check the admission section byte-for-byte as well as the stop/reap lifecycle.
    first, last = 'host = available()\n', '(root/\'once\').mkdir()'
    assert text[text.index(first):text.index(last)] == old[old.index(first):old.index(last)]
    outputs['fp-compare-synthesis-r1/run.py'] = text

    old = original['window-current-clock-r2/run.py']
    text = baseline(common(old))
    text = replace(text, str(ROOT / 'synthesis-r1'), str(ROOT / 'window-current-synthesis-r2'))
    text = replace(text, 'e1d89ee8d386289e4d29bf4c89304800d68f7d2999762061dc929983abdb58c8', PARENT_DCP)
    clock_guarded(text, old)
    outputs['fp-compare-clock-r1/run.py'] = text

    text = common(original['window-current-synthesis-r2/audit_closed.py'])
    text = replace(text, str(ROOT / 'synthesis-r1'), str(ROOT / 'window-current-synthesis-r2'))
    text = replace(text, str(ROOT / 'fpga-r1'), str(ROOT / 'window-current-fpga-r1'))
    text = replace(text, '8e8ab037834da5120453149a60766b4455f60be0e14e06f6a7be33a19aa5b864', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes=' + repr(CHANGES) + '\n')
    text = replace(text, 'two-file environment-write/current-tag transfer', 'two-file next-tag/FP-classifier transfer')
    outputs['fp-compare-synthesis-r1/audit_closed.py'] = text
    text = common(original['window-current-clock-r2/audit_closed.py'])
    outputs['fp-compare-clock-r1/audit_closed.py'] = replace(text, '(-2.909)', '(-5.277)')
    outputs['fp-compare-clock-r1/audit.tcl'] = original['window-current-clock-r2/audit.tcl']
    for name, content in outputs.items():
        if name.endswith('.py'): ast.parse(content, filename=name)
    return outputs


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root == ROOT and Path(os.environ['TMPDIR']).resolve() == SCRATCH
    source = root / 'fp-compare-fpga-r1'
    assert sha(source / 'input-manifest.json') == MANIFEST
    manifest = json.loads((source / 'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    assert set(manifest['changed_parent_payloads']) == set(CHANGES)
    assert sha(root / 'fp-compare-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    for name, digest in CHANGES.items():
        assert sha(source / name) == digest
        assert native.transform(name.removeprefix('ventium/'), (root / 'window-current-fpga-r1' / name).read_text()) == (source / name).read_text()
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        path = ROOT / name
        assert sha(path) == digest
        original[name] = path.read_text()
        pins[str(path)] = digest
    for path in (Path(__file__), Path(native.__file__), native.original, Path(native.next_tag.__file__),
                 Path(native.classifier.__file__), Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py'),
                 Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(path.resolve())] = sha(path)
    outputs = derive(original)
    receipt = root / 'fp-compare-timing-prepared.json'
    assert not receipt.exists() and all(not (root / name).exists() for name in outputs)
    for name, content in outputs.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as f: f.write(content)
    with receipt.open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n): sha(root/n) for n in outputs},
            source_manifest_sha256=MANIFEST, model_sha256=MODEL, canonical_gate_passed=False,
            standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None), f, indent=2)
    print('Prepared guarded FP-classifier/next-tag experiment; nothing launched.', flush=True)


if __name__ == '__main__': main()
