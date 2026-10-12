#!/usr/bin/env python3
"""Prepare matched load-ACK synthesis/audits; preserve the resource controller."""
import argparse
import ast
import json
import os
from pathlib import Path

from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded

PARENT=Path('/home/yukidama/external/tmp/ventium-srt-rem-split.pM3Jsjhi').resolve(strict=True)
OLDER=Path('/home/yukidama/external/tmp/ventium-mc-pair-srt.fI8m6eUS').resolve(strict=True)
MANIFEST='09805c9c641b7b741fdf70c4547f0d4a8adbfa448d47be31c27a176d4d02c341'
MODEL='89ebdd625be3f65e97c1ddafee6e166084ed3978c27d96f5f96b6509144f0a09'
CORE='6d53d0934c9a3c6e7e89d632ccf0d677a0360b4dcb3caeeb917a1f131bd6e6cc'
TEMPLATES={
    'synthesis-r1/run.py':'05d1d420cad4355384a01a20e2f1c5e8bd5a54c877bb5afa3d328d7d39016931',
    'synthesis-r1/audit_closed.py':'fc30ef26266c27f9f7618033cea8700fb2bc917d05cfe07e4c787fcbb395f63d',
    'clock-r1/run.py':'3fe3481c4fed4c881009ad60a7a409ec7609f9f3a6f3e0d3f973c401900d624b',
    'clock-r1/audit_closed.py':'dd2a774407b2d9b20f7b2b4343e0b623cc139acd46deeb1fe4523c4756c83936',
    'clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}
CHANGES={'ventium/rtl/core/core_load.svh':'9f87375e8dd20bd11016d2aa7991410d5f0e32cd59f3d2f364f64ce44f537be2'}


def derive(original):
    result={}
    for phase in ('synthesis','clock'):
        key=phase+'-r1/run.py'; text=original[key]
        text=text.replace('ventium-rem-split-','ventium-load-read-ack-')
        text=replace(text,"manifest['variant'] == 'rem_split_timing'","manifest['variant'] == 'load_read_ack_timing'")
        if phase=='synthesis':
            text=replace(text,"changes=['fp_shared/ven_fp_top.sv','rtl/core/core.sv','rtl/fpu/fpu_srt_div.sv']",
                         "changes=['rtl/core/core_load.svh']")
            text=replace(text,'37250c5f8b7350d77b7e102e5fc6b7ebb99c078873534634e84f142c0b779329',CORE)
            text=replace(text,"assert prepared['added_defines']==['VEN_SRT_REM_OPERAND_SPLIT']",
                         "assert prepared['added_defines']==[]")
            text=span(text,'    rationale=','    generic_gate=',
                "    rationale='Read-only load completion cofactor. Matched Default logic-only mapper, real 40/100 MHz clocks, UV+fast and full P5 L1. Parent 29.69650175 MHz. No timing, canonical or board pass inherited.',\n")
            text=replace(text,'"""Measure the source-matched bus cancellation timing candidate; no route or deployment."""',
                         '"""Measure the source-matched load-ACK timing candidate; no route or deployment."""')
        else:
            text=replace(text,str(OLDER/'payload-current-synthesis-r1'),str(PARENT/'synthesis-r1'))
            text=replace(text,'0ce21a979f339fbbc6ef0cd4ed3747b8b3faccb1dcdffe45da0d0ddb9c874ffa',
                         '538e3b5e4dd6ac5bb09ae38d291e979a24005b05f1729db3b39543879a05ee6a')
        guarded(text,original[key])
        result[key]=text
    text=original['synthesis-r1/audit_closed.py']
    text=replace(text,str(OLDER/'payload-current-synthesis-r1'),str(PARENT/'synthesis-r1'))
    text=replace(text,str(OLDER/'payload-current-fpga-r1'),str(PARENT/'fpga-r1'))
    text=replace(text,'ventium-rem-split-synth-oct12.service','ventium-load-read-ack-synth-oct12.service')
    text=replace(text,'1f78fbf6d9384f8e79a558f25d6e2b9a2b3e3a7a286fd8100f3f8764daca87f2',
                 '4329eff21cca7394e53cba00944ac165bd95b7d52fff35bdad76acc4d89d2d79')
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(CHANGES)+'\n')
    text=replace(text,"assert [d for d in manifest['hardware_defines'] if d != 'VEN_SRT_REM_OPERAND_SPLIT'] == old_manifest['hardware_defines']",
                 "assert manifest['hardware_defines'] == old_manifest['hardware_defines']")
    text=replace(text,"only_added_define='VEN_SRT_REM_OPERAND_SPLIT'","only_added_define=None")
    text=text.replace('three tested RTL deltas','one tested RTL delta').replace(
        'Only the checked remainder operand define is added; no clock change or timing waiver.',
        'All feature definitions and clocks are unchanged; no timing waiver.')
    result['synthesis-r1/audit_closed.py']=text
    text=original['clock-r1/audit_closed.py']
    text=replace(text,'ventium-rem-split-clock-oct12.service','ventium-load-read-ack-clock-oct12.service')
    text=replace(text,'(-7.998)','(-8.674)')
    result['clock-r1/audit_closed.py']=text
    result['clock-r1/audit.tcl']=original['clock-r1/audit.tcl']
    for name,text in result.items():
        if name.endswith('.py'): ast.parse(text,filename=name)
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    root=parser.parse_args().root.resolve(strict=True)
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root==scratch/'ventium-load-read-ack.GyWDDtiI'
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert sha(root/'fpga-r1/input-manifest.json')==MANIFEST
    assert sha(root/'soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted')==MODEL
    original,pins={},{}
    for name,digest in TEMPLATES.items():
        p=PARENT/name; assert sha(p)==digest
        original[name]=p.read_text(); pins[str(p)]=digest
    for p in (Path(__file__),Path(__file__).with_name('prepare_fragment_exact_timing.py'),
              Path(__file__).with_name('prepare_payload_current_synthesis.py')): pins[str(p)]=sha(p)
    outputs=derive(original)
    receipt=root/'timing-prepared.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in outputs)
    for name,text in outputs.items():
        p=root/name; p.parent.mkdir(parents=True,exist_ok=True)
        with p.open('x') as stream: stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in outputs},source_manifest_sha256=MANIFEST,
            model_sha256=MODEL,canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
            fmax_mhz=None,gameplay_ipc=None),stream,indent=2)
    print('Prepared guarded load-ACK synthesis and clock audits; nothing launched.',flush=True)
