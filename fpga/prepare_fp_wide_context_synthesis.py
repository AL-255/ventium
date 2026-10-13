"""Prepare matched contextual-FP synthesis/timing controllers; launch nothing.

Preserve the single-family resource/watchdog lifecycle and original 40/100 MHz
constraints. Control is the closed 34.113392918 MHz PAYLOAD-REGION netlist.
The canonical gate remains red; this is timing exploration, not acceptance.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_fp_wide_context_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
PARENT_MANIFEST = '5e5bdf083c4d2ba7f678a2fd46f9dab794d15fd1a286cc904497fdc6eb503603'
PARENT_DCP = 'cb4d787acf141663525776e7865af81e80bc585fbbcf9885efaa72ea65e828fd'
TEMPLATES = {
    'payload-region-synthesis-r1/run.py': '117e6c0b64604aa692be308f861545a57f2a29b4ddc59f3d5a554c6e4a35942f',
    'payload-region-synthesis-r1/audit_closed.py': '28a300e9997f8bf3f0837ed67bd9d9b34cb19458ac5d03120719514cfc0e84ae',
    'payload-region-clock-r1/run.py': 'f8e5d1695f12defe42ddef9b8240713e109b5a8a76360a542fa9723f07ca1297',
    'payload-region-clock-r1/audit_closed.py': '7135d7cdbae515097da82633f4cc57bfc5dda01b4f663df323d83848a0e16495',
    'payload-region-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def derive(original, changes):
    assert sorted(changes) == ['ventium/'+n for n in native.CHANGES]
    result = {}
    for phase in ('synthesis', 'clock'):
        name = 'payload-region-'+phase+'-r1/run.py'
        text = original[name].replace('payload-region-', 'fp-wide-context-')
        text = replace(text, 'oct12.service', 'oct13.service', 1 if phase == 'synthesis' else 2)
        text = replace(text, "manifest['variant'] == 'payload_region_timing'",
                       "manifest['variant'] == 'fp_wide_context_timing'")
        if phase == 'synthesis':
            text = replace(text, '3a91aa88841f949855d27e0ed500064854ad9b24390c318629054de858061164', native.CORE_MODEL)
            text = replace(text, "changes=['rtl/mem/ven_l1d.sv', 'rtl/mem/ventium_l1_axi.sv']",
                           'changes='+repr(native.CHANGES))
            text = replace(text, 'source-matched payload-only cache-region hint',
                           'source-matched FP-only contextual wide response')
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Remove only next-request arbitration from the FP-only wide-valid consumer, whose FLOAD state excludes all PIPE lookahead offers. Ordinary cache grants, cycles and ownership unchanged. Same logic-only mapper, UV+fast/full P5 caches and original 40/100 MHz clocks. Matched PAYLOAD-REGION control is 34.113392918 MHz. Canonical remains FAIL; no route, board or timing pass inherited.',\n")
        else:
            text = replace(text, str(ROOT/'intent-ready-synthesis-r1'), str(ROOT/'payload-region-synthesis-r1'))
            text = replace(text, '497f354881a1cb7836ca3d0acd9babc8e364865b7f1af871acf2131f346b84d1', PARENT_DCP)
        guarded(text, original[name])
        result['fp-wide-context-'+phase+'-r1/run.py'] = text
    text = original['payload-region-synthesis-r1/audit_closed.py'].replace('payload-region-', 'fp-wide-context-')
    text = replace(text, 'oct12.service', 'oct13.service')
    for suffix in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(ROOT/('intent-ready-'+suffix)), str(ROOT/('payload-region-'+suffix)))
    text = replace(text, '034095db8f09866e527046fd6f130a950759f3798c3a72d69bfd53d5756a2c1b', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(changes)+'\n')
    text = replace(text, 'Audit the two tested payload-region files', 'Audit the four tested FP contextual files')
    result['fp-wide-context-synthesis-r1/audit_closed.py'] = text
    text = original['payload-region-clock-r1/audit_closed.py'].replace('payload-region-', 'fp-wide-context-')
    text = replace(text, 'oct12.service', 'oct13.service')
    result['fp-wide-context-clock-r1/audit_closed.py'] = replace(text, '(-5.162)', '(-4.314)')
    result['fp-wide-context-clock-r1/audit.tcl'] = original['payload-region-clock-r1/audit.tcl']
    for name, text in result.items():
        if name.endswith('.py'):
            ast.parse(text, filename=name)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == ROOT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    source = root/'fp-wide-context-fpga-r1'
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant'] == 'fp_wide_context_timing' and manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    pc = root/'fp-wide-context-soc-r1'
    closed = json.loads((pc/'build-closed.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit'] == 0
    model = sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert model == closed['binary_sha256'] == manifest['simulator_sha256']
    changes = {name: sha(source/name) for name in manifest['changed_parent_payloads']}
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        path = root/name
        assert sha(path) == digest
        original[name] = path.read_text()
        pins[str(path)] = digest
    for path in (Path(__file__), Path(native.__file__), native.original, Path(native.recipe.__file__),
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py')):
        pins[str(path)] = sha(path)
    output = derive(original, changes)
    receipt = root/'fp-wide-context-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in output)
    for name, text in output.items():
        path = root/name
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as stream:
            stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n): sha(root/n) for n in output},
            source_manifest_sha256=sha(source/'input-manifest.json'), model_sha256=model,
            canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
            fmax_mhz=None, gameplay_ipc=None), stream, indent=2)
    print('Prepared guarded contextual-FP synthesis/timing controllers; nothing launched.', flush=True)


if __name__ == '__main__':
    main()
