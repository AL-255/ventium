#!/usr/bin/env python3
"""Prepare matched synthesis/clock audits without changing the resource lifecycle."""
import argparse
import ast
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

PARENT = Path('/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS').resolve(strict=True)
MANIFEST = '4329eff21cca7394e53cba00944ac165bd95b7d52fff35bdad76acc4d89d2d79'
MODEL = '61763f61ef15dadd24602e8cc86b1b4e3bdab75b5bc2c3280d84ad90bdb8cd58'
PARENT_DCP = '0ce21a979f339fbbc6ef0cd4ed3747b8b3faccb1dcdffe45da0d0ddb9c874ffa'
TEMPLATES = {
    'payload-current-synthesis-r1/run.py': 'b5731e0816d05bb10855bffd494806c84eacc33ef8668a46c581ba18b8b63299',
    'payload-current-synthesis-r1/audit_closed.py': '9addbf256a9936d1c4f99d4aeb1b3b8ef786824e42737b29ec0c99dfef1c435f',
    'payload-current-clock-r1/run.py': 'd367e0f80415e4ef255043d78112178d90a0617ca5bd2675643ef822c1bb7b00',
    'payload-current-clock-r1/audit_closed.py': '305205e75a4b5b12fd6e41547732f560d96c7e8399c97603590c9359aa4106f5',
    'payload-current-clock-r1/audit.tcl': 'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
CHANGES = {
    'ventium/fp_shared/ven_fp_top.sv': '76b259bdc51534127a7bed77f3389a5971ef6b3774e1229c0785e74474c1e5ef',
    'ventium/rtl/core/core.sv': '552ad08f48da2833f7d299c37c9f73455f5cd08eafdbbc1fa129ccc10906c985',
    'ventium/rtl/fpu/fpu_srt_div.sv': '76cb1b6cde27b18f230286d706bf0383f7989a8848fe57ef439f024258ad0c7f',
}
PROOF = '''verify=load_proof('core-r1/verify-closed.json')
assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']
assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
assert len(verify['deltas'])==20 and all(r['same_records'] for r in verify['deltas'])
core=load_proof('core-r1/build-started.json')
changes=['fp_shared/ven_fp_top.sv','rtl/core/core.sv','rtl/fpu/fpu_srt_div.sv']
assert core['changes']==changes and len(core['definitions'])==152
build=load_proof('core-r1/build-closed.json')
assert build['passed'] and build['native_exit']==0 and build['pins_unchanged'] and not build['errors']
assert build['binary_sha256']=='37250c5f8b7350d77b7e102e5fc6b7ebb99c078873534634e84f142c0b779329'
pins.update(core['pins'])
replay=load_proof('canonical-r1/closed.json')
assert replay['same_input_regression_passed'] and replay['pins_unchanged'] and not replay['errors']
assert len(replay['rows'])==108 and replay['records']==80800 and not replay['canonical_gate_passed']
pins.update(load_proof('canonical-r1/started.json')['pins'])
prepared=load_proof('soc-r1/prepared.json')
assert len(prepared['intersecting_rtl_sources'])==102 and prepared['changes']==changes
assert prepared['added_defines']==['VEN_SRT_REM_OPERAND_SPLIT']
assert prepared['directed_model']==build['binary_sha256']
pins.update(prepared['pins'])
pc=load_proof('soc-r1/build-closed.json')
assert pc['passed'] and pc['native_exit']==0 and pc['inputs_unchanged'] and not pc['errors']
assert pc['binary_sha256']==model and pc['structural_warnings_unchanged'] and pc['structural_debt_count']==98
timing=load_proof('timing-prepared.json')
assert timing['unchanged_guard_lifecycle'] and timing['controllers_generated_not_launched']
pins.update(timing['template_pins']); pins.update(timing['outputs'])
assert all(sha(p)==h for p,h in pins.items())
'''


def derive(original):
    result = {}
    old_synth = str(PARENT/'prime-noack/synthesis-logic-r1')
    parent_synth = str(PARENT/'payload-current-synthesis-r1')
    for phase in ('synthesis','clock'):
        key = 'payload-current-'+phase+'-r1/run.py'; text = original[key]
        text = replace(text,"source = root.parent/'payload-current-fpga-r1'","source = root.parent/'fpga-r1'")
        text = text.replace('ventium-payload-current-','ventium-rem-split-')
        text = replace(text,"manifest['variant'] == 'payload_current_timing'","manifest['variant'] == 'rem_split_timing'")
        text = replace(text,"len(manifest['hardware_defines']) == 157","len(manifest['hardware_defines']) == 158")
        text = replace(text,"root.parent/'payload-current-lint-r1/closed.json'","root.parent/'lint-r1/closed.json'")
        if phase == 'synthesis':
            text = span(text,"verify=load_proof('payload-current-core-r1/verify-closed.json')",
                        "cmroot=root.parent/'payload-current-soc-r1/coremark'",PROOF)
            text = replace(text,"cmroot=root.parent/'payload-current-soc-r1/coremark'","cmroot=root.parent/'soc-r1/coremark'")
            text = span(text,'    rationale=','    generic_gate=',
                "    rationale='SRT remainder operand isolation and read-only V clear. Matched Default logic-only mapper, real 40/100 MHz clocks, UV+fast and full P5 L1. Parent 30.30486696 MHz. No timing, canonical or board pass inherited.',\n")
        else:
            text = replace(text,"synthesis = root.parent/'payload-current-synthesis-r1'","synthesis = root.parent/'synthesis-r1'")
            text = replace(text,old_synth,parent_synth)
            text = replace(text,'2a734a6d33ff623254a88e2fa3ec40078d340ed45533e0f02c9767694f36661b',PARENT_DCP)
        guarded(text,original[key])
        result[phase+'-r1/run.py'] = text
    key = 'payload-current-synthesis-r1/audit_closed.py'; text = original[key]
    text = replace(text,"source = root.parent / 'payload-current-fpga-r1'","source = root.parent / 'fpga-r1'")
    text = replace(text,old_synth,parent_synth)
    text = replace(text,str(PARENT/'prime-noack/fpga-r1'),str(PARENT/'payload-current-fpga-r1'))
    text = replace(text,'ventium-payload-current-synth-oct12.service','ventium-rem-split-synth-oct12.service')
    text = replace(text,'485aec1484e25676312315347b406a80122f2e58a13065f8bdf39ac1f089a755',
                   '1f78fbf6d9384f8e79a558f25d6e2b9a2b3e3a7a286fd8100f3f8764daca87f2')
    text = span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(CHANGES)+'\n')
    text = text.replace('VEN_L1D_PAYLOAD_CODE_HINT','VEN_SRT_REM_OPERAND_SPLIT')
    text = replace(text,".index('VEN_SRT_REM_OPERAND_SPLIT') == 153",".index('VEN_SRT_REM_OPERAND_SPLIT') == 154")
    text = replace(text,"len(manifest['hardware_defines']) == 157","len(manifest['hardware_defines']) == 158")
    text = replace(text,'actual_defines=157','actual_defines=158')
    text = text.replace('four tested RTL deltas','three tested RTL deltas').replace('payload hint define','remainder operand define')
    result['synthesis-r1/audit_closed.py'] = text
    text = original['payload-current-clock-r1/audit_closed.py']
    text = replace(text,'ventium-payload-current-clock-oct12.service','ventium-rem-split-clock-oct12.service')
    text = replace(text,'(-9.621)','(-7.998)')
    result['clock-r1/audit_closed.py'] = text
    result['clock-r1/audit.tcl'] = original['payload-current-clock-r1/audit.tcl']
    for name,text in result.items():
        if name.endswith('.py'): ast.parse(text,filename=name)
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__); ap.add_argument('--root',type=Path,required=True)
    root = ap.parse_args().root.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root == scratch/'ventium-srt-rem-split.pM3Jsjhi'
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert sha(root/'fpga-r1/input-manifest.json') == MANIFEST
    assert sha(root/'soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted') == MODEL
    original, pins = {}, {}
    for name,digest in TEMPLATES.items():
        p = PARENT/name; assert sha(p) == digest
        original[name] = p.read_text(); pins[str(p)] = digest
    for p in (Path(__file__).resolve(),Path(__file__).with_name('prepare_fragment_exact_timing.py'),
              Path(__file__).with_name('prepare_payload_current_synthesis.py')): pins[str(p)] = sha(p)
    outputs = derive(original)
    receipt = root/'timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in outputs)
    for name,text in outputs.items():
        p = root/name; p.parent.mkdir(parents=True,exist_ok=True)
        with p.open('x') as stream: stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in outputs},
            source_manifest_sha256=MANIFEST,model_sha256=MODEL,canonical_gate_passed=False,
            standard_suite=False,hardware_acceptance=False,fmax_mhz=None,gameplay_ipc=None),stream,indent=2)
    print('Prepared guarded SRT/V-clear synthesis and clock audits; nothing launched.',flush=True)


if __name__ == '__main__': main()
