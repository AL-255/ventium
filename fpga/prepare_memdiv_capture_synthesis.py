#!/usr/bin/env python3
"""Prepare the two-divider-change experiment with unchanged Vivado safeguards.

Only source/evidence identities change from the closed fetch-probe controllers.
This does not launch synthesis or qualify a build for deployment.
"""
import argparse
import ast
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
MANIFEST = '0859a74cc3539b1644c90813029c02e0545d1b002184e33cd94f6ecbe6ed68cb'
MODEL = '10d875b4cf1680d50906434ee3d5572ce1ee0f8175a792c8a7554d8728c6f3fe'
CORE = 'be5375aa32db48600498fc4b2c3a610c7cd99a0fa208c5186e602c44dd9b3d10'
PARENT_MANIFEST = '6e8db80a61959c273141140c77d7c7351d38b19616557c12e19b9d9dc40c0ee0'
PARENT_DCP = '934c8741b51440be4dfda0bfacfa4f551d352cbc7482638836bce9342c5eb907'
TEMPLATES = {
    'probe-synthesis-r1/run.py': 'ba0b3a7d51a08164fce64b4d0239603f10fd406adc80ea23c54fcad65afb96be',
    'probe-synthesis-r1/audit_closed.py': '68d89d997e40ba230a548d69ea0213b9d900dd3e58bc544330bc46acba1d0cca',
    'probe-clock-r1/run.py': '4b5e3b71f64fe86981ab5fa8fda517b575655d1698b3c89553753002c714ea9c',
    'probe-clock-r1/audit_closed.py': '4013056c94ed90f7ef84e88c3d58188ed8d2eb4802b38eac0f2d61fb16d41d88',
    'probe-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
CHANGES = {
    'ventium/fp_shared/ven_fp_top.sv': 'de65098da526dd472b34ac0b46c664d55ef60617305cc93e7e68fafcf7a92c57',
    'ventium/rtl/fpu/fpu_srt_div.sv': '40b3e77b051bb674f99a30f3c9eb37566c06b32487d567a9ee78eaccbb833cbb',
}


def derive(original):
    output = {}
    for phase in ('synthesis', 'clock'):
        key = 'probe-'+phase+'-r1/run.py'
        text = original[key].replace('ventium-fetch-probe-', 'ventium-memdiv-')
        for old, new, count in (
            ("source = root.parent/'probe-fpga-r1'", "source = root.parent/'memdiv-fpga-r1'", 1),
            ("root.parent/'probe-lint-r1/closed.json'", "root.parent/'memdiv-lint-r1/closed.json'", 1),
            ("manifest['variant'] == 'fetch_probe_payload_timing'", "manifest['variant'] == 'memdiv_capture_timing'", 1)):
            text = replace(text, old, new, count)
        if phase == 'synthesis':
            for old, new, count in (
                ("'probe-payload-core-r1/", "'memdiv-core-r1/", 3),
                ("'probe-canonical-replay-r1/", "'memdiv-replay-r1/", 2),
                ("'probe-soc-r1/", "'memdiv-soc-r1/", 3),
                ('probe-timing-prepared.json', 'memdiv-timing-prepared.json', 1),
                ('9097e2ae0c56e26a66f7dabeb631820bdb196ebeda7da1c132a9ea10f7758265', CORE, 1)):
                text = replace(text, old, new, count)
            text = replace(text, "changes=['rtl/core/core.sv']",
                           "changes=['fp_shared/ven_fp_top.sv','rtl/fpu/fpu_srt_div.sv']")
            # The directed core derives from the exponent core; the PC derives
            # from fetch-probe, so its audited delta correctly contains both.
            text = replace(text, "core['changes']==changes", "core['changes']==changes[:1]")
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Memory FDIV raw-input register and bounded SRT exponent arithmetic. Same Default logic-only mapper, 40/100 MHz clocks, UV+fast and full P5 L1. Parent 30.487804878 MHz. Canonical gate remains FAIL; no board or timing pass inherited.',\n")
            text = replace(text, 'source-matched fetch-probe timing candidate',
                           'source-matched memory-divide timing candidate')
        else:
            text = replace(text, "synthesis = root.parent/'probe-synthesis-r1'",
                           "synthesis = root.parent/'memdiv-synthesis-r1'")
            text = replace(text, str(ROOT/'synthesis-r1'), str(ROOT/'probe-synthesis-r1'))
            text = replace(text, '5710a825be2f623f2749fb421dcf6b4daa24a999270e3099655bbc30fb1f471f', PARENT_DCP)
        guarded(text, original[key])
        output['memdiv-'+phase+'-r1/run.py'] = text

    text = original['probe-synthesis-r1/audit_closed.py']
    text = replace(text, "source = root.parent / 'probe-fpga-r1'", "source = root.parent / 'memdiv-fpga-r1'")
    for name in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(ROOT/name), str(ROOT/('probe-'+name)))
    text = replace(text, 'ventium-fetch-probe-synth-oct12.service', 'ventium-memdiv-synth-oct12.service')
    text = replace(text, '09805c9c641b7b741fdf70c4547f0d4a8adbfa448d47be31c27a176d4d02c341', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    text = replace(text, 'Audit one tested RTL delta', 'Audit two tested RTL deltas')
    output['memdiv-synthesis-r1/audit_closed.py'] = text
    text = original['probe-clock-r1/audit_closed.py']
    text = replace(text, 'ventium-fetch-probe-clock-oct12.service', 'ventium-memdiv-clock-oct12.service')
    text = replace(text, '(-8.309)', '(-7.800)')
    output['memdiv-clock-r1/audit_closed.py'] = text
    output['memdiv-clock-r1/audit.tcl'] = original['probe-clock-r1/audit.tcl']
    for name, text in output.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return output


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', required=True, type=Path)
    root = ap.parse_args().root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == ROOT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert sha(root/'memdiv-fpga-r1/input-manifest.json') == MANIFEST
    assert sha(root/'memdiv-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        p = root/name; assert sha(p) == digest
        original[name] = p.read_text(); pins[str(p)] = digest
    for name in ('prepare_memdiv_capture_synthesis.py','prepare_fragment_exact_timing.py',
                 'prepare_payload_current_synthesis.py'):
        p = Path(__file__).with_name(name); pins[str(p)] = sha(p)
    result = derive(original)
    receipt = root/'memdiv-timing-prepared.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in result)
    for name, text in result.items():
        p = root/name; p.parent.mkdir(parents=True, exist_ok=True)
        with p.open('x') as f: f.write(text)
    with receipt.open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in result},
            source_manifest_sha256=MANIFEST,model_sha256=MODEL,canonical_gate_passed=False,
            standard_suite=False,hardware_acceptance=False,fmax_mhz=None,gameplay_ipc=None),f,indent=2)
    print('Prepared memory-divide synthesis/timing controllers; nothing launched.',flush=True)


if __name__ == '__main__': main()
