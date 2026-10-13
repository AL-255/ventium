"""Prepare the payload-region synthesis and matched parent timing audit.

Preserve the native exclusive/resource/watchdog lifecycle and original clocks.
The control is the closed 33.154300113 MHz INTENT-READY synthesized netlist.
Nothing is launched here; canonical failures and board acceptance stay open.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_payload_region_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
PARENT_MANIFEST = '034095db8f09866e527046fd6f130a950759f3798c3a72d69bfd53d5756a2c1b'
PARENT_DCP = '497f354881a1cb7836ca3d0acd9babc8e364865b7f1af871acf2131f346b84d1'
TEMPLATES = {
    'intent-ready-synthesis-r1/run.py':'ad5158f3f199c2e0d3e185b7cd58344764d8dad5e7a0e1912b605e2aa6300bf5',
    'intent-ready-synthesis-r1/audit_closed.py':'aabc157c01bd574c42e984fe2a5b179dbbc240908aff5b2fb8782f043f991ed3',
    'intent-ready-clock-r1/run.py':'e95b59909e6389383f897a7af6e323d2c65dfc3cae2c00fa16da45ccd01b0643',
    'intent-ready-clock-r1/audit_closed.py':'c4b39f5d16d3d135ccf6eae5cad6c0dcb63f8cd32ecc66132ceef7c9752e4b99',
    'intent-ready-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def derive(original, changes):
    assert sorted(changes) == ['ventium/'+n for n in native.CHANGES]
    result = {}
    for phase in ('synthesis','clock'):
        name = 'intent-ready-'+phase+'-r1/run.py'
        text = original[name].replace('intent-ready-', 'payload-region-')
        text = replace(text, "manifest['variant'] == 'intent_ready_timing'",
                       "manifest['variant'] == 'payload_region_timing'")
        if phase == 'synthesis':
            text = replace(text, '6fa8f7ad89e4f84a3c484a5e8c81d933e9bda429ca6c7019bd5e2c63d3ce1b5e', native.CORE_MODEL)
            text = replace(text, 'source-matched intent-only paired readiness',
                           'source-matched payload-only cache-region hint')
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Remove the redundant last-byte cache-map dependency only from aligned-dword payload selection; retain full extent checks for every control and all registered response owners. Same logic-only mapper, UV+fast/full P5 caches and original 40/100 MHz clocks. Matched source/timing control INTENT-READY is 33.154300113 MHz. Canonical remains FAIL; no route, board or timing pass inherited.',\n")
        else:
            text = replace(text, str(ROOT/'fresh-pair-synthesis-r1'), str(ROOT/'intent-ready-synthesis-r1'))
            text = replace(text, '32b06bb08c58472c577a0ff046301643ffba2cab13600f17103f8c32d8c5960d', PARENT_DCP)
        guarded(text, original[name])
        result['payload-region-'+phase+'-r1/run.py'] = text
    text = original['intent-ready-synthesis-r1/audit_closed.py'].replace('intent-ready-', 'payload-region-')
    for suffix in ('synthesis-r1','fpga-r1'):
        text = replace(text, str(ROOT/('fresh-pair-'+suffix)), str(ROOT/('intent-ready-'+suffix)))
    text = replace(text, '0c767b0435e78a86aa0f61907dff21f9a2184aedea071d209a1230eb10e4ced7', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(changes)+'\n')
    text = replace(text, 'Audit the two tested intent-ready files', 'Audit the two tested payload-region files')
    result['payload-region-synthesis-r1/audit_closed.py'] = text
    text = original['intent-ready-clock-r1/audit_closed.py'].replace('intent-ready-', 'payload-region-')
    result['payload-region-clock-r1/audit_closed.py'] = replace(text, '(-6.424)', '(-5.162)')
    result['payload-region-clock-r1/audit.tcl'] = original['intent-ready-clock-r1/audit.tcl']
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
    source = root/'payload-region-fpga-r1'
    manifest = json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant'] == 'payload_region_timing' and manifest['parent_manifest_sha256'] == PARENT_MANIFEST
    pc = root/'payload-region-soc-r1'
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
    receipt = root/'payload-region-timing-prepared.json'
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
    print('Prepared guarded payload-region synthesis/timing controllers; nothing launched.', flush=True)


if __name__ == '__main__': main()
