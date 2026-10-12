"""Prepare matched-parent synthesis of the immediate paired-load completion cut.

Reuse closed controllers with unchanged mapper, clocks, process ownership and
memory/disk safeguards. Preparation neither launches Vivado nor grants acceptance.
"""
import argparse
import ast
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
MANIFEST = 'b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'
MODEL = '45dc4daf68980bba3ca36f9b8d2c6c4ec4464a07657f70669f00e085478893f5'
CORE = '66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750'
PARENT_MANIFEST = 'a15a7ec363d5ce5cd894a9d8e7f3a238cf0c57dc2086febe35c5587e787ef4be'
PARENT_DCP = '58069b79e9e9c52ba93a5ce4a528e0aae96b478ba5ac8a02c0b9fca084f3ea1b'
TEMPLATES = {
    'memdiv-query-synthesis-r1/run.py': '82a664aa2e645794cefac55b8637826d3502547c78227714eadc859b0b97d4d4',
    'memdiv-query-synthesis-r1/audit_closed.py': '8dddea20dcf6d33e1fd76b3f5ab52dd8753367e93fd8246c92a71663eed988fe',
    'memdiv-query-clock-r1/run.py': '9afaebad0ae6981ed7b0eccdca75c2fdaf3188d4d406035258c24acddffabfdd',
    'memdiv-query-clock-r1/audit_closed.py': 'c29f3fc2cd4af4fd685a98a004b188d47459474b98b91da8735248456fb28bb3',
    'memdiv-query-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
CHANGES = {'ventium/rtl/core/core.sv': '94652b5d10c48beed5133a2c318880a511c7ae3f4490363a0e81df2f92fdacb2'}


def derive(original):
    output = {}
    for phase in ('synthesis','clock'):
        key = 'memdiv-query-'+phase+'-r1/run.py'
        text = original[key].replace('memdiv-query-', 'pair-now-read-')
        text = replace(text, "manifest['variant'] == 'memdiv_query_payload_timing'",
                       "manifest['variant'] == 'pair_now_read_ack_timing'")
        if phase == 'synthesis':
            text = replace(text, "changes=['rtl/core/core_mem_chain.svh']", "changes=['rtl/core/core.sv']")
            text = replace(text, 'e65a06e1e3c26d48723bdeb0d9d97061879f15b1ff916e493d4fe94ae336a525', CORE)
            text = span(text, '    rationale=', '    generic_gate=',
                "    rationale='Immediate V-load completion uses the existing fragment-qualified read ACK. Same Default logic-only mapper, 40/100 MHz clocks, UV+fast and full P5 L1. Measured parent 30.676728634 MHz. Actual immediate-path witnesses and complete A/B cycles pass; canonical gate remains FAIL. No timing or board pass inherited.',\n")
            text = replace(text, 'source-matched resident-query timing candidate',
                           'source-matched immediate paired-read timing candidate')
        else:
            text = replace(text, str(ROOT/'memdiv-synthesis-r1'), str(ROOT/'memdiv-query-synthesis-r1'))
            text = replace(text, 'da8395424004b9016f9c7a4822271aa0c3234daef8cc2d97dc8d987a4e89d950', PARENT_DCP)
        guarded(text, original[key])
        output['pair-now-read-'+phase+'-r1/run.py'] = text
    text = original['memdiv-query-synthesis-r1/audit_closed.py']
    text = text.replace('memdiv-query-', 'pair-now-read-')
    for name in ('synthesis-r1','fpga-r1'):
        text = replace(text, str(ROOT/('memdiv-'+name)), str(ROOT/('memdiv-query-'+name)))
    text = replace(text, '0859a74cc3539b1644c90813029c02e0545d1b002184e33cd94f6ecbe6ed68cb', PARENT_MANIFEST)
    text = span(text, 'expected_changes=', 'assert set(changed)', 'expected_changes='+repr(CHANGES)+'\n')
    output['pair-now-read-synthesis-r1/audit_closed.py'] = text
    text = original['memdiv-query-clock-r1/audit_closed.py'].replace('memdiv-query-', 'pair-now-read-')
    text = replace(text, '(-9.391)', '(-7.598)')
    output['pair-now-read-clock-r1/audit_closed.py'] = text
    output['pair-now-read-clock-r1/audit.tcl'] = original['memdiv-query-clock-r1/audit.tcl']
    for name, text in output.items():
        if name.endswith('.py'): ast.parse(text, filename=name)
    return output


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',required=True,type=Path)
    root = ap.parse_args().root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root==ROOT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert sha(root/'pair-now-read-fpga-r1/input-manifest.json')==MANIFEST
    assert sha(root/'pair-now-read-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted')==MODEL
    original, pins = {}, {}
    for name,digest in TEMPLATES.items():
        p=root/name; assert sha(p)==digest
        original[name]=p.read_text(); pins[str(p)]=digest
    for name in ('prepare_pair_now_read_synthesis.py','prepare_fragment_exact_timing.py',
                 'prepare_payload_current_synthesis.py'):
        p=Path(__file__).with_name(name); pins[str(p)]=sha(p)
    output=derive(original)
    receipt=root/'pair-now-read-timing-prepared.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in output)
    for name,text in output.items():
        p=root/name; p.parent.mkdir(parents=True,exist_ok=True)
        with p.open('x') as stream: stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in output},
            source_manifest_sha256=MANIFEST,model_sha256=MODEL,canonical_gate_passed=False,
            standard_suite=False,hardware_acceptance=False,fmax_mhz=None,gameplay_ipc=None),stream,indent=2)
    print('Prepared immediate paired-read synthesis/timing controllers; nothing launched.',flush=True)


if __name__=='__main__': main()
