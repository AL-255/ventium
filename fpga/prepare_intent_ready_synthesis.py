"""Prepare, but do not launch, intent-ready synthesis and matched clock audits.

Retain native resource/watchdog guards, original clocks and logic-only mapper.
Source and timing control are the closed 31.822810591 MHz FRESH-PAIR build.
Canonical failures remain unwaived; no route or physical acceptance is claimed.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_intent_ready_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
PARENT_MANIFEST = '0c767b0435e78a86aa0f61907dff21f9a2184aedea071d209a1230eb10e4ced7'
PARENT_DCP = '32b06bb08c58472c577a0ff046301643ffba2cab13600f17103f8c32d8c5960d'
TEMPLATES = {
    'fresh-pair-synthesis-r1/run.py':'3efb4a408ca21e3f56f04f6166d471d132805a9e70123c506791a57262991d2a',
    'fresh-pair-synthesis-r1/audit_closed.py':'fe59ae1a7e86a63ab14e8835d4d92ab2a1e80222309819b3df05976399b43872',
    'fresh-pair-clock-r1/run.py':'c3bd7af364f690c5a533e240914e3d121dd58d8203e97dd3b179cc3be7c533f1',
    'fresh-pair-clock-r1/audit_closed.py':'161039bbcae23cc86f75902fd342e1717afd40000dfca251123f7df7519e58b9',
    'fresh-pair-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def derive(original, changes):
    assert sorted(changes) == ['ventium/'+n for n in native.CHANGES]
    result = {}
    for phase in ('synthesis','clock'):
        name = 'fresh-pair-'+phase+'-r1/run.py'
        text = original[name].replace('fresh-pair-', 'intent-ready-')
        text = replace(text, "manifest['variant'] == 'fresh_pair_capture_timing'",
                       "manifest['variant'] == 'intent_ready_timing'")
        if phase == 'synthesis':
            text = replace(text, "changes=['rtl/mem/ven_l1d.sv']", 'changes='+repr(native.CHANGES))
            text = replace(text, 'e1621913f28c5cd1c10b0c19f57bc59277807034dfb6b94a79bd7fe58d6a1a81', native.CORE_MODEL)
            text = replace(text, 'source-matched fresh paired capture', 'source-matched intent-only paired readiness')
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Remove next-request qualification only from intent-qualified pair readiness; retain ordinary readiness, lookup arbitration, backing credit and cycle behavior. Same logic-only mapper, UV+fast/full P5 caches and original 40/100 MHz clocks. Matched source/timing control FRESH-PAIR is 31.822810591 MHz. Canonical remains FAIL; no route, board or timing pass inherited.',\n")
        else:
            text = replace(text, str(ROOT/'pair-intent-synthesis-r1'), str(ROOT/'fresh-pair-synthesis-r1'))
            text = replace(text, 'b03f67ee2a42326723a1f16ef0c529d546878cbbcdcbcee783c1086d3e4b2df8', PARENT_DCP)
        guarded(text, original[name])
        result['intent-ready-'+phase+'-r1/run.py'] = text
    text = original['fresh-pair-synthesis-r1/audit_closed.py'].replace('fresh-pair-', 'intent-ready-')
    for suffix in ('synthesis-r1','fpga-r1'):
        text = replace(text, str(ROOT/('read-owner-'+suffix)), str(ROOT/('fresh-pair-'+suffix)))
    text = replace(text, '90e4ec12f6d61699a175484366450a41d67a8d7b1717b3d228f8b5b0ab8bb87c', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(changes)+'\n')
    text = replace(text, 'Audit the one tested fresh paired-capture file', 'Audit the two tested intent-ready files')
    result['intent-ready-synthesis-r1/audit_closed.py'] = text
    text = original['fresh-pair-clock-r1/audit_closed.py'].replace('fresh-pair-', 'intent-ready-')
    result['intent-ready-clock-r1/audit_closed.py'] = replace(text, '(-6.594)', '(-6.424)')
    result['intent-ready-clock-r1/audit.tcl'] = original['fresh-pair-clock-r1/audit.tcl']
    for name,text in result.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == ROOT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    source = root/'intent-ready-fpga-r1'
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant'] == 'intent_ready_timing' and manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    pc = root/'intent-ready-soc-r1'
    closed = json.loads((pc/'build-closed.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit'] == 0
    model = sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert model == closed['binary_sha256'] == manifest['simulator_sha256']
    changes = {name:sha(source/name) for name in manifest['changed_parent_payloads']}
    original, pins = {}, {}
    for name,digest in TEMPLATES.items():
        path = root/name
        assert sha(path) == digest
        original[name] = path.read_text(); pins[str(path)] = digest
    for path in (Path(__file__), Path(native.__file__), native.original, Path(native.recipe.__file__),
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py')):
        pins[str(path)] = sha(path)
    output = derive(original, changes)
    receipt = root/'intent-ready-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in output)
    for name,text in output.items():
        path = root/name; path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('x') as stream: stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n):sha(root/n) for n in output},
            source_manifest_sha256=sha(source/'input-manifest.json'), model_sha256=model,
            canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
            fmax_mhz=None, gameplay_ipc=None), stream, indent=2)
    print('Prepared guarded intent-ready synthesis/timing controllers; nothing launched.', flush=True)


if __name__ == '__main__': main()
