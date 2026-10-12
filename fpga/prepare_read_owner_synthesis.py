"""Prepare one source-matched read-owner timing experiment; launch nothing.

Keep the closed PAIR-INTENT lifecycle, resource reserves and original clocks.
Require the FP/fault regressions as well as core/PC/replay/CoreMark evidence.
The latest 31.651579 MHz checkpoint is the source and timing control.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_read_owner_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
PARENT_MANIFEST = '06a4179627952a02aa8444fe91b2a44d5f1dd11bf1f56c5bd0ff07bc232d7777'
PARENT_DCP = 'b03f67ee2a42326723a1f16ef0c529d546878cbbcdcbcee783c1086d3e4b2df8'
TEMPLATES = {
    'pair-intent-synthesis-r1/run.py': 'e5f90467ec749cbf022a50778227263918fee4f9f8448a3555c72cfeeb1855a9',
    'pair-intent-synthesis-r1/audit_closed.py': '4666626ad7c590e2cb663e209ba70d268524f9bcc34127eab8a1083b7acda8ed',
    'pair-intent-clock-r1/run.py': 'fbb0330df32ba62662a5ce17dd9dea9abd9c6d92c7b1009a7ae6d069555cbfe0',
    'pair-intent-clock-r1/audit_closed.py': '1fc1f54207d746d289d2cf6ca04cb04d28b9fe6e4797e41347408709fba7f7e8',
    'pair-intent-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
EXTRA_PROOF = '''reg=load_proof('read-owner-regressions-r1/closed.json')
assert reg['passed'] and reg['pins_unchanged'] and not reg['errors']
assert not reg['canonical_gate_passed'] and len(reg['rows'])==12
assert [r['label'] for r in reg['rows']]==[
    'boundary-0','boundary-1','boundary-24','boundary-25','boundary-29','boundary-4093',
    'faults','integer','memory','held','branch','replay']
for row in reg['rows']:
    assert row['native_exit']==0
    receipt=proof/'read-owner-regressions-r1'/row['label']/('result.json' if row['label']=='held' else 'closed.json')
    assert sha(receipt)==row['receipt_sha256']
    pins[str(receipt)]=row['receipt_sha256']
pins.update(load_proof('read-owner-regressions-r1/started.json')['pins'])
fp=load_proof('read-owner-fp-r1/closed.json')
assert fp['passed'] and fp['pins_unchanged'] and not fp['errors']
assert len(fp['measurements'])==1536 and len(fp['deltas'])==768
assert all(r['saved_clocks']==0 for r in fp['deltas'])
pins.update(load_proof('read-owner-fp-r1/started.json')['pins'])
'''


def derive(original, changes):
    assert sorted(changes) == ['ventium/'+p for p in native.CHANGES]
    output = {}
    for phase in ('synthesis', 'clock'):
        name = 'pair-intent-'+phase+'-r1/run.py'
        text = original[name].replace('pair-intent-', 'read-owner-')
        text = replace(text, "manifest['variant'] == 'pair_intent_timing'",
                       "manifest['variant'] == 'read_owner_ack_timing'")
        if phase == 'synthesis':
            text = span(text, 'changes=', "assert core['changes']", 'changes='+repr(native.CHANGES)+'\n')
            text = span(text, "assert len(prepared['intersecting_rtl_sources'])", "assert prepared['added_defines']",
                        "assert len(prepared['intersecting_rtl_sources'])==102 and prepared['changes']==changes\n")
            text = replace(text, 'f3fb3256fb40d9af50d73f2ac80b26bb4f5e27ff4b95d9f279172b4e0c025e41', native.CORE_MODEL)
            assert text.count('read-owner-replay-r1/') == 2
            text = text.replace('read-owner-replay-r1/', 'read-owner-regressions-r1/replay/')
            text = replace(text, "cmroot=root.parent/'read-owner-soc-r1/coremark'",
                           EXTRA_PROOF+"cmroot=root.parent/'read-owner-soc-r1/coremark'")
            text = replace(text, 'source-matched checked cache-port intent arbiter',
                           'source-matched current-owner read completion')
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Absorb speculative lookup from current-owner read ACK only. Preserve data/capture, architectural cycles, UV+fast and full P5 caches. Same logic-only mapper and original 40/100 MHz constraints. Source and best retained parent PAIR-INTENT is 31.651579 MHz. Canonical remains FAIL; no timing, route or board pass inherited.',\n")
        else:
            text = replace(text, str(ROOT/'memdiv-query-synthesis-r1'), str(ROOT/'pair-intent-synthesis-r1'))
            text = replace(text, '58069b79e9e9c52ba93a5ce4a528e0aae96b478ba5ac8a02c0b9fca084f3ea1b', PARENT_DCP)
        guarded(text, original[name])
        output['read-owner-'+phase+'-r1/run.py'] = text
    text = original['pair-intent-synthesis-r1/audit_closed.py'].replace('pair-intent-', 'read-owner-')
    for suffix in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(ROOT/('backing-payload-'+suffix)), str(ROOT/('pair-intent-'+suffix)))
    text = replace(text, 'd6f856259c0cdef90c0ef3f1a97b0a5568bdba13b8eb9d3a8332fc351bc90c20', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(changes)+'\n')
    text = replace(text, 'Audit four tested hardware files and one simulation-only probe',
                   'Audit the one tested current-owner read ACK file')
    output['read-owner-synthesis-r1/audit_closed.py'] = text
    text = original['pair-intent-clock-r1/audit_closed.py'].replace('pair-intent-', 'read-owner-')
    output['read-owner-clock-r1/audit_closed.py'] = replace(text, '(-7.598)', '(-6.594)')
    output['read-owner-clock-r1/audit.tcl'] = original['pair-intent-clock-r1/audit.tcl']
    for name, text in output.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    root = parser.parse_args().root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == ROOT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    source = root/'read-owner-fpga-r1'
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant'] == 'read_owner_ack_timing' and manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    pc = root/'read-owner-soc-r1'; closed = json.loads((pc/'build-closed.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit'] == 0
    model = sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert model == closed['binary_sha256'] == manifest['simulator_sha256']
    changes = {name:sha(source/name) for name in manifest['changed_parent_payloads']}
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        p = root/name; assert sha(p) == digest
        original[name] = p.read_text(); pins[str(p)] = digest
    for p in (Path(__file__), Path(native.__file__), native.original, Path(native.recipe.__file__),
              Path(__file__).with_name('prepare_fragment_exact_timing.py'),
              Path(__file__).with_name('prepare_payload_current_synthesis.py')):
        pins[str(p)] = sha(p)
    output = derive(original, changes); receipt = root/'read-owner-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in output)
    for name, text in output.items():
        p = root/name; p.parent.mkdir(parents=True, exist_ok=True)
        with p.open('x') as stream: stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n):sha(root/n) for n in output},
            source_manifest_sha256=sha(source/'input-manifest.json'), model_sha256=model,
            canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
            fmax_mhz=None, gameplay_ipc=None), stream, indent=2)
    print('Prepared bounded read-owner synthesis/timing controllers; nothing launched.', flush=True)


if __name__ == '__main__': main()
