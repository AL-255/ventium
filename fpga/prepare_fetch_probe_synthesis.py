#!/usr/bin/env python3
"""Prepare fetch-probe synthesis/audits without altering resource safeguards."""
import argparse
import ast
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

PARENT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
OLDER = Path('/home/yukidama/external/tmp/ventium-srt-rem-split.pM3Jsjhi').resolve(strict=True)
MANIFEST = '6e8db80a61959c273141140c77d7c7351d38b19616557c12e19b9d9dc40c0ee0'
MODEL = 'b598f07768e3e04483a3c11dca8d97ff35acd134d2b3f94a54fb56d3e1f21b71'
CORE = '9097e2ae0c56e26a66f7dabeb631820bdb196ebeda7da1c132a9ea10f7758265'
TEMPLATES = {
    'synthesis-r1/run.py': '1bc7b00db84993f5fbf49aed7d93764cb9b6fb140f0aff6bd9fe62483d6ed4a4',
    'synthesis-r1/audit_closed.py': '47824828ef26b27e9275a40aeb0ef8b7493400f73b89fd094b34c30461cfe7f3',
    'clock-r1/run.py': 'b27ce6d3ad5f61420c47f836fd42a0450636588387e85a17afb3944923c03006',
    'clock-r1/audit_closed.py': 'ce8227f9f9f36a650548883c85cd95d61a4acd8de6a5301aece35ef7548958d2',
    'clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
CHANGES = {'ventium/rtl/core/core.sv': '70cc3e386aaa7c359b09021cd6c3e38803bfd6ab93533ede73611a74f9694837'}


def derive(original):
    result = {}
    for phase in ('synthesis', 'clock'):
        key = phase+'-r1/run.py'; text = original[key]
        text = text.replace('ventium-load-read-ack-', 'ventium-fetch-probe-')
        text = replace(text, "source = root.parent/'fpga-r1'", "source = root.parent/'probe-fpga-r1'")
        text = replace(text, "root.parent/'lint-r1/closed.json'", "root.parent/'probe-lint-r1/closed.json'")
        text = replace(text, "manifest['variant'] == 'load_read_ack_timing'",
                       "manifest['variant'] == 'fetch_probe_payload_timing'")
        if phase == 'synthesis':
            text = replace(text, "changes=['rtl/core/core_load.svh']", "changes=['rtl/core/core.sv']")
            text = replace(text, '6d53d0934c9a3c6e7e89d632ccf0d677a0360b4dcb3caeeb917a1f131bd6e6cc', CORE)
            for old, new, count in (('core-r1/', 'probe-payload-core-r1/', 3),
                    ('canonical-r1/', 'probe-canonical-replay-r1/', 2),
                    ('soc-r1/', 'probe-soc-r1/', 3), ('timing-prepared.json', 'probe-timing-prepared.json', 1)):
                assert text.count("'"+old) == count, (old, text.count("'"+old))
                text = text.replace("'"+old, "'"+new)
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Early fetch-probe payload only; active probe authority unchanged. Matched Default logic-only mapper, real 40/100 MHz clocks, UV+fast and full P5 L1. Parent 30.021915999 MHz. No timing, canonical or board pass inherited.',\n")
            text = replace(text, 'source-matched load-ACK timing candidate', 'source-matched fetch-probe timing candidate')
        else:
            text = replace(text, "synthesis = root.parent/'synthesis-r1'", "synthesis = root.parent/'probe-synthesis-r1'")
            text = replace(text, str(OLDER/'synthesis-r1'), str(PARENT/'synthesis-r1'))
            text = replace(text, '538e3b5e4dd6ac5bb09ae38d291e979a24005b05f1729db3b39543879a05ee6a',
                           '5710a825be2f623f2749fb421dcf6b4daa24a999270e3099655bbc30fb1f471f')
        guarded(text, original[key])
        result['probe-'+key] = text
    text = original['synthesis-r1/audit_closed.py']
    text = replace(text, "source = root.parent / 'fpga-r1'", "source = root.parent / 'probe-fpga-r1'")
    for name in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(OLDER/name), str(PARENT/name))
    text = replace(text, 'ventium-load-read-ack-synth-oct12.service', 'ventium-fetch-probe-synth-oct12.service')
    text = replace(text, '4329eff21cca7394e53cba00944ac165bd95b7d52fff35bdad76acc4d89d2d79',
                   '09805c9c641b7b741fdf70c4547f0d4a8adbfa448d47be31c27a176d4d02c341')
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    result['probe-synthesis-r1/audit_closed.py'] = text
    text = original['clock-r1/audit_closed.py']
    text = replace(text, 'ventium-load-read-ack-clock-oct12.service', 'ventium-fetch-probe-clock-oct12.service')
    text = replace(text, '(-8.674)', '(-8.309)')
    result['probe-clock-r1/audit_closed.py'] = text
    result['probe-clock-r1/audit.tcl'] = original['clock-r1/audit.tcl']
    for name, text in result.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    root = parser.parse_args().root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == PARENT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert sha(root/'probe-fpga-r1/input-manifest.json') == MANIFEST
    assert sha(root/'probe-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        p = PARENT/name; assert sha(p) == digest
        original[name] = p.read_text(); pins[str(p)] = digest
    for p in (Path(__file__), Path(__file__).with_name('prepare_fragment_exact_timing.py'),
              Path(__file__).with_name('prepare_payload_current_synthesis.py')): pins[str(p)] = sha(p)
    outputs = derive(original)
    receipt = root/'probe-timing-prepared.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in outputs)
    for name, text in outputs.items():
        p = root/name; p.parent.mkdir(parents=True, exist_ok=True)
        with p.open('x') as stream: stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n):sha(root/n) for n in outputs}, source_manifest_sha256=MANIFEST,
            model_sha256=MODEL, canonical_gate_passed=False, standard_suite=False, hardware_acceptance=False,
            fmax_mhz=None, gameplay_ipc=None), stream, indent=2)
    print('Prepared guarded fetch-probe synthesis and clock audits; nothing launched.', flush=True)
