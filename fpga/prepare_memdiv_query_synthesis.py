"""Prepare the exact-parent query-selector timing measurement.

Reuse the closed memory-divide controllers with unchanged resource/ownership
safeguards, mapper and clocks. Only source/evidence identities change. Neither
preparation nor a successful audit establishes 40 MHz or board qualification.
"""
import argparse
import ast
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
MANIFEST = 'a15a7ec363d5ce5cd894a9d8e7f3a238cf0c57dc2086febe35c5587e787ef4be'
MODEL = 'eebeb872631af564d340958bfe0c3576ab7ac9c56fb18b7f57af2b2a9ea50987'
CORE = 'e65a06e1e3c26d48723bdeb0d9d97061879f15b1ff916e493d4fe94ae336a525'
PARENT_MANIFEST = '0859a74cc3539b1644c90813029c02e0545d1b002184e33cd94f6ecbe6ed68cb'
PARENT_DCP = 'da8395424004b9016f9c7a4822271aa0c3234daef8cc2d97dc8d987a4e89d950'
TEMPLATES = {
    'memdiv-synthesis-r1/run.py': '0faeedb2775e2a3475bea361f34d089510f0700cfd2142d207ae0e9e66b8cf80',
    'memdiv-synthesis-r1/audit_closed.py': '441501c95c2e8c453f8de3515215a1d6cd110604e85d8be3d03f7749c95c9b1e',
    'memdiv-clock-r1/run.py': 'e44a9c4d64c227ca9d6c40d3500f56c005bcf84de9a4c7f411b8d7db5e097ab9',
    'memdiv-clock-r1/audit_closed.py': '43b1adfab0e1cedbeb62d987f93af2937cc98f61eb0a1570a8922402262b1ce8',
    'memdiv-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
CHANGES = {'ventium/rtl/core/core_mem_chain.svh': '6e888ab63a31a9100f1e4afd6ee61159111b10518d336ea5fdf0a1aa915ecde4'}


def derive(original):
    output = {}
    for phase in ('synthesis', 'clock'):
        key = 'memdiv-'+phase+'-r1/run.py'
        text = original[key].replace('ventium-memdiv-', 'ventium-memdiv-query-')
        text = text.replace("'memdiv-", "'memdiv-query-")
        text = replace(text, "manifest['variant'] == 'memdiv_capture_timing'",
                       "manifest['variant'] == 'memdiv_query_payload_timing'")
        if phase == 'synthesis':
            text = replace(text, "changes=['fp_shared/ven_fp_top.sv','rtl/fpu/fpu_srt_div.sv']",
                           "changes=['rtl/core/core_mem_chain.svh']")
            text = replace(text, "core['changes']==changes[:1]", "core['changes']==changes")
            text = replace(text, 'be5375aa32db48600498fc4b2c3a610c7cd99a0fa208c5186e602c44dd9b3d10', CORE)
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Resident-query payload selection by registered owner, removing the late request qualification from address/strobe selection. Same Default logic-only mapper, 40/100 MHz clocks, UV+fast and full P5 L1. Measured parent 29.077374895 MHz. Canonical gate remains FAIL; no timing or board pass inherited.',\n")
            text = replace(text, 'source-matched memory-divide timing candidate',
                           'source-matched resident-query timing candidate')
        else:
            text = replace(text, str(ROOT/'probe-synthesis-r1'), str(ROOT/'memdiv-synthesis-r1'))
            text = replace(text, '934c8741b51440be4dfda0bfacfa4f551d352cbc7482638836bce9342c5eb907', PARENT_DCP)
        guarded(text, original[key])
        output['memdiv-query-'+phase+'-r1/run.py'] = text
    text = original['memdiv-synthesis-r1/audit_closed.py']
    text = replace(text, "source = root.parent / 'memdiv-fpga-r1'", "source = root.parent / 'memdiv-query-fpga-r1'")
    for name in ('synthesis-r1', 'fpga-r1'):
        text = replace(text, str(ROOT/('probe-'+name)), str(ROOT/('memdiv-'+name)))
    text = replace(text, 'ventium-memdiv-synth-oct12.service', 'ventium-memdiv-query-synth-oct12.service')
    text = replace(text, '6e8db80a61959c273141140c77d7c7351d38b19616557c12e19b9d9dc40c0ee0', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    text = replace(text, 'Audit two tested RTL deltas', 'Audit one tested RTL delta')
    output['memdiv-query-synthesis-r1/audit_closed.py'] = text
    text = original['memdiv-clock-r1/audit_closed.py']
    text = replace(text, 'ventium-memdiv-clock-oct12.service', 'ventium-memdiv-query-clock-oct12.service')
    text = replace(text, '(-7.800)', '(-9.391)')
    output['memdiv-query-clock-r1/audit_closed.py'] = text
    output['memdiv-query-clock-r1/audit.tcl'] = original['memdiv-clock-r1/audit.tcl']
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
    assert sha(root/'memdiv-query-fpga-r1/input-manifest.json') == MANIFEST
    assert sha(root/'memdiv-query-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    original, pins = {}, {}
    for name, digest in TEMPLATES.items():
        p = root/name; assert sha(p) == digest
        original[name] = p.read_text(); pins[str(p)] = digest
    for name in ('prepare_memdiv_query_synthesis.py', 'prepare_fragment_exact_timing.py',
                 'prepare_payload_current_synthesis.py'):
        p = Path(__file__).with_name(name); pins[str(p)] = sha(p)
    output = derive(original)
    receipt = root/'memdiv-query-timing-prepared.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in output)
    for name, text in output.items():
        p = root/name; p.parent.mkdir(parents=True, exist_ok=True)
        with p.open('x') as f: f.write(text)
    with receipt.open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True, unchanged_guard_lifecycle=True,
            template_pins=pins, outputs={str(root/n):sha(root/n) for n in output},
            source_manifest_sha256=MANIFEST, model_sha256=MODEL, canonical_gate_passed=False,
            standard_suite=False, hardware_acceptance=False, fmax_mhz=None, gameplay_ipc=None), f, indent=2)
    print('Prepared query-selector synthesis/timing controllers; nothing launched.', flush=True)


if __name__ == '__main__': main()
