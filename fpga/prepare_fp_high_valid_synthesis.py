"""Prepare guarded synthesis of the tested three-file FP response cut.

Preserve the exact closed controller lifecycle, mapper, clocks and resource
limits. Compare source changes against PAIR-NOW-READ, and independently measure
timing against the better MEMDIV-QUERY checkpoint (30.676729 MHz).
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_fp_high_valid_soc as native
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

ROOT=Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)
PARENT_MANIFEST='b47ea1b537c4ea1fd763f81ee23c506b39838218a0969c0ed94baf82ab46eb6b'
TEMPLATES={
    'pair-now-read-synthesis-r1/run.py':'b4f623142462034268c02ee3b2c30e0cb845c9adb08852fd2b80b5c1d705f2d7',
    'pair-now-read-synthesis-r1/audit_closed.py':'7925dd876b9d3146c02cdde14cdb8a09a777b2001a2cc8f2af08e498b4070bec',
    'pair-now-read-clock-r1/run.py':'ebf8ed3f100e88b5ae503c966b1836306b83ab3341fbacde074acdfb2314aacc',
    'pair-now-read-clock-r1/audit_closed.py':'4c71a6ab7f75b0f23a71a0c2e7188e7462849f4c63667d484f20e8c28ac3a9c0',
    'pair-now-read-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def derive(original, changes):
    assert sorted(changes)==['ventium/'+name for name in native.CHANGES]
    output={}
    for phase in ('synthesis','clock'):
        key='pair-now-read-'+phase+'-r1/run.py'
        text=original[key].replace('pair-now-read-','fp-high-valid-')
        text=replace(text,"manifest['variant'] == 'pair_now_read_ack_timing'",
                     "manifest['variant'] == 'fp_high_valid_timing'")
        if phase=='synthesis':
            text=replace(text,"changes=['rtl/core/core.sv']",'changes='+repr(native.CHANGES))
            text=replace(text,'66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750',native.CORE_MODEL)
            text=text.replace('fp-high-valid-replay-r1/','fp-high-valid-regressions-r2/replay/')
            text=span(text,'    rationale=','    generic_gate=',
                "    rationale='Three exact-source response cofactors remove duplicate ACK dependencies. Same Default logic-only mapper, 40/100 MHz clocks, UV+fast and full P5 caches. Source parent PAIR-NOW-READ is 29.953572 MHz; independent timing comparison retains the best MEMDIV-QUERY checkpoint at 30.676729 MHz. Canonical remains FAIL; no board or timing pass inherited.',\n")
            text=replace(text,'source-matched immediate paired-read timing candidate',
                         'source-matched wide FP response timing candidate')
        # The clock controller deliberately keeps MEMDIV-QUERY as its parent.
        guarded(text,original[key])
        output['fp-high-valid-'+phase+'-r1/run.py']=text
    text=original['pair-now-read-synthesis-r1/audit_closed.py'].replace('pair-now-read-','fp-high-valid-')
    for name in ('synthesis-r1','fpga-r1'):
        text=replace(text,str(ROOT/('memdiv-query-'+name)),str(ROOT/('pair-now-read-'+name)))
    text=replace(text,'a15a7ec363d5ce5cd894a9d8e7f3a238cf0c57dc2086febe35c5587e787ef4be',PARENT_MANIFEST)
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(changes)+'\n')
    text=replace(text,'Audit one tested RTL delta','Audit three tested RTL deltas')
    text=replace(text,"'ventium/rtl/mem/ven_axi_master.sv', 'ventium/rtl/mem/ven_l1d.sv',",
                 "'ventium/rtl/mem/ven_axi_master.sv', 'ventium/rtl/mem/ven_l1d.sv', 'ventium/rtl/mem/ventium_l1_axi.sv',")
    output['fp-high-valid-synthesis-r1/audit_closed.py']=text
    output['fp-high-valid-clock-r1/audit_closed.py']=original['pair-now-read-clock-r1/audit_closed.py'].replace(
        'pair-now-read-','fp-high-valid-')
    output['fp-high-valid-clock-r1/audit.tcl']=original['pair-now-read-clock-r1/audit.tcl']
    for name,text in output.items():
        if name.endswith('.py'): ast.parse(text,filename=name)
    return output


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root==ROOT and root.is_relative_to(scratch)
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    source=root/'fp-high-valid-fpga-r1'
    manifest=json.loads((source/'input-manifest.json').read_text())
    assert manifest['variant']=='fp_high_valid_timing' and manifest['parent_manifest_sha256']==PARENT_MANIFEST
    pc=root/'fp-high-valid-soc-r1'
    closed=json.loads((pc/'build-closed.json').read_text())
    assert closed['passed'] and closed['inputs_unchanged'] and closed['native_exit']==0
    model=sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert model==closed['binary_sha256']==manifest['simulator_sha256']
    changes={name:sha(source/name) for name in manifest['changed_parent_payloads']}
    assert sorted(changes)==['ventium/'+name for name in native.CHANGES]
    original,pins={},{}
    for name,digest in TEMPLATES.items():
        p=root/name; assert sha(p)==digest
        original[name]=p.read_text(); pins[str(p)]=digest
    for name in ('prepare_fp_high_valid_synthesis.py','prepare_fragment_exact_timing.py',
                 'prepare_payload_current_synthesis.py','build_fp_high_valid_soc.py'):
        p=Path(__file__).with_name(name); pins[str(p)]=sha(p)
    output=derive(original,changes)
    receipt=root/'fp-high-valid-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in output)
    for name,text in output.items():
        p=root/name; p.parent.mkdir(parents=True,exist_ok=True)
        with p.open('x') as stream: stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/name):sha(root/name) for name in output},
            source_manifest_sha256=sha(source/'input-manifest.json'),model_sha256=model,
            canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
            fmax_mhz=None,gameplay_ipc=None),stream,indent=2)
    print('Prepared guarded FP response synthesis/timing controllers; nothing launched.',flush=True)


if __name__=='__main__': main()
