"""Prepare fresh-pair synthesis and timing controllers without launching them.

The closed READ-OWNER flow supplies the unchanged native resource lifecycle.
Compare area/source against READ-OWNER and timing against best PAIR-INTENT.
All directed, FP/fault, replay, short CoreMark and lint evidence is mandatory;
canonical failures stay unwaived. This is not hardware acceptance.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_fresh_pair_soc as native
from prepare_fragment_exact_timing import replace,sha,span
from prepare_payload_current_synthesis import guarded

ROOT=Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
# Pinned historical templates retain the previous host's resolved mount path.
# Rebase only that exact path in generated copies; never rewrite the evidence.
TEMPLATE_ROOT=Path('/run/media/yukidama/f213d338-6002-424a-9968-584cf4aff9b6/tmp/ventium-load-read-ack.GyWDDtiI')
PARENT_MANIFEST='90e4ec12f6d61699a175484366450a41d67a8d7b1717b3d228f8b5b0ab8bb87c'
BEST_DCP='b03f67ee2a42326723a1f16ef0c529d546878cbbcdcbcee783c1086d3e4b2df8'
TEMPLATES={
    'read-owner-synthesis-r1/run.py':'4dde35bd9e076220c318a2954ff04af487258d227a2f3d493f93c69071cee5b9',
    'read-owner-synthesis-r1/audit_closed.py':'5c430d128c3287c9cd005e3fa0ff08aac80c3908c161906e0497354612d37bbd',
    'read-owner-clock-r1/run.py':'73edb71dc2d1466480fccce1314801856e84d422df92773332baa9978e3f5164',
    'read-owner-clock-r1/audit_closed.py':'92c28dde54b7fba521e8e8c906611eebc689a175ec07d07832a2e1e7c20790d4',
    'read-owner-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def derive(original,changes):
    assert sorted(changes)==['ventium/'+n for n in native.CHANGES]
    original={name:text.replace(str(TEMPLATE_ROOT),str(ROOT)) for name,text in original.items()}
    result={}
    for phase in ('synthesis','clock'):
        name='read-owner-'+phase+'-r1/run.py'
        text=original[name].replace('read-owner-','fresh-pair-')
        text=replace(text,"manifest['variant'] == 'read_owner_ack_timing'",
                     "manifest['variant'] == 'fresh_pair_capture_timing'")
        if phase=='synthesis':
            text=replace(text,'3091744d8c87eef66ed5c598d43575a80e2e8de6d0790a478de96fb0b96cb9d2',native.CORE_MODEL)
            text=replace(text,'source-matched current-owner read completion','source-matched fresh paired capture')
            text=span(text,'    rationale=','    generic_gate=',
                "    rationale='Cofactor fresh current-U paired capture without next-lookup, extent or saved-window mux dependencies. Preserve data, cycles, UV+fast and full P5 caches. Same logic-only mapper and original 40/100 MHz clocks. Source parent READ-OWNER is 31.040477 MHz; retained best timing control PAIR-INTENT is 31.651579 MHz. Canonical remains FAIL; no route, board or timing pass inherited.',\n")
        guarded(text,original[name])
        result['fresh-pair-'+phase+'-r1/run.py']=text
    text=original['read-owner-synthesis-r1/audit_closed.py'].replace('read-owner-','fresh-pair-')
    for suffix in ('synthesis-r1','fpga-r1'):
        text=replace(text,str(ROOT/('pair-intent-'+suffix)),str(ROOT/('read-owner-'+suffix)))
    text=replace(text,'06a4179627952a02aa8444fe91b2a44d5f1dd11bf1f56c5bd0ff07bc232d7777',PARENT_MANIFEST)
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(changes)+'\n')
    text=replace(text,'Audit the one tested current-owner read ACK file','Audit the one tested fresh paired-capture file')
    result['fresh-pair-synthesis-r1/audit_closed.py']=text
    result['fresh-pair-clock-r1/audit_closed.py']=original['read-owner-clock-r1/audit_closed.py'].replace('read-owner-','fresh-pair-')
    result['fresh-pair-clock-r1/audit.tcl']=original['read-owner-clock-r1/audit.tcl']
    for name,text in result.items():
        if name.endswith('.py'): ast.parse(text,filename=name)
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root==ROOT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    source=root/'fresh-pair-fpga-r1';manifest=json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant']=='fresh_pair_capture_timing' and manifest['parent_manifest_sha256']==PARENT_MANIFEST
    pc=root/'fresh-pair-soc-r1';closed=json.loads((pc/'build-closed.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    model=sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert model==closed['binary_sha256']==manifest['simulator_sha256']
    changes={name:sha(source/name) for name in manifest['changed_parent_payloads']}
    original,pins={},{}
    for name,digest in TEMPLATES.items():
        path=root/name;assert sha(path)==digest
        original[name]=path.read_text();pins[str(path)]=digest
    for path in (Path(__file__),Path(native.__file__),native.original,Path(native.recipe.__file__),
                 Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py')):
        pins[str(path)]=sha(path)
    output=derive(original,changes);receipt=root/'fresh-pair-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in output)
    for name,text in output.items():
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('x') as stream:stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in output},
            source_manifest_sha256=sha(source/'input-manifest.json'),model_sha256=model,
            canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
            fmax_mhz=None,gameplay_ipc=None),stream,indent=2)
    print('Prepared guarded fresh-pair synthesis/timing controllers; nothing launched.',flush=True)


if __name__=='__main__':main()
