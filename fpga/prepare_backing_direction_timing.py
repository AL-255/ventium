"""Prepare matched one-file timing diagnosis; preserve every CAD resource guard."""
import ast
import json
import os
from pathlib import Path

import backing_direction_evidence as evidence
from prepare_fragment_exact_timing import replace,sha,span
from prepare_payload_current_synthesis import guarded as synth_guarded
from prepare_v_result_carry_clock import guarded as clock_guarded

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
SOURCE='backing-direction-fpga-r1'
SYNTH='backing-direction-synthesis-r1'
CLOCK='backing-direction-clock-r1'
RECEIPT='backing-direction-timing-prepared-r1.json'
TEMPLATES={
 'posted-mouse-synthesis-r1/run.py':'551edec82ea7cfae290601f78f29e92f4e3056aa1eef053416c5f51ae39d5550',
 'posted-mouse-synthesis-r1/audit_closed.py':'d16bbdb7dd3514ea5cb501e86fd285ffe253689aa418ec93aa303cbc7a701504',
 'posted-mouse-synthesis-r1/launch_checked.tcl':'725abb0abf9758d6bcec583ef1209b9213797eb371efcf8733d91a0518c200e7',
 'posted-mouse-clock-r1/run.py':'4cd73ff086e51b936eb9152feee38d366b4b013fdd3c756287ca78f6fd7d3851',
 'posted-mouse-clock-r1/audit_closed.py':'1b3848fa7081e83b3bccb077a6bd1644eea885bc226117aa39fb6e63e7c7d8b7',
 'posted-mouse-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666'}


def common(text):
    assert 'ventium-posted-mouse-synth-oct16-r1.service' in text
    for phase in ('synth','clock'):
        text=text.replace(f'ventium-posted-mouse-{phase}-oct16-r1.service',
                          f'ventium-backing-direction-{phase}-oct16-r1.service')
    for old,new in (
        ('v-result-carry-posted-mouse-fpga-r1',SOURCE),
        (evidence.mouse.VARIANT,evidence.VARIANT),
        ('v-result-carry-lint-r1/closed.json','backing-direction-lint-r1/closed.json'),
        (evidence.mouse.repair.PARENT_SHA,evidence.MANIFEST),
        ('posted_mouse_evidence as mouse_evidence','backing_direction_evidence as mouse_evidence'),
        ('posted-mouse-timing-prepared-r1.json',RECEIPT),
        ('baseline_gameplay_ipc=0.50520554,baseline_window=[5600065237,5700065237]',
         'baseline_gameplay_ipc=0.48146083,baseline_window=[1100065247,1200065247]'),
        ('c7b95b78f47f5e709136f98230bdf33975cf8db0e925956b469649cbf6384afd',
         '7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68')):
        assert old in text,old;text=text.replace(old,new)
    return text


def derive(original):
    output={}
    old=original['posted-mouse-synthesis-r1/run.py'];text=common(old)
    for before,after in (
        ('build_v_result_carry_soc as native','build_backing_direction_soc as native'),
        ('v-result-carry-soc-r1','backing-direction-soc-r1'),
        ('v-result-carry-core-r1','backing-direction-core-r1'),
        ('v-result-carry-matched-r1','backing-direction-matched-r1'),
        ('native.recipe.transform(before,name)','native.recipe.transform(before)')):
        assert before in text;text=text.replace(before,after)
    text=span(text,'    rationale=','    generic_gate=',
        "    rationale='One exact L1 inactive-direction delta on the corrected posted-DDR mouse parent. "
        "Same 159 defines, complete source closure, mapper and 40/100 MHz constraints. "
        "Active packets, admission and cycles unchanged in native regression. Canonical FAIL retained. "
        "Timing diagnosis only: no route, suite, bitstream or physical qualification.',\n")
    synth_guarded(text,old)
    a,b='host = available()\n',"(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)]==old[old.index(a):old.index(b)]
    output[SYNTH+'/run.py']=text
    audit=original['posted-mouse-synthesis-r1/audit_closed.py']
    audit=replace(audit,"source = root.parent / 'v-result-carry-posted-mouse-fpga-r1'",f"source = root.parent / '{SOURCE}'")
    audit=audit.replace('ventium-posted-mouse-synth-oct16-r1.service','ventium-backing-direction-synth-oct16-r1.service')
    audit=replace(audit,str(ROOT/'pipe-wait-synthesis-r1'),str(ROOT/'posted-mouse-synthesis-r1'))
    audit=replace(audit,str(ROOT/'pipe-wait-fpga-r1'),str(ROOT/'v-result-carry-posted-mouse-fpga-r1'))
    audit=replace(audit,'d655cc8bf1dcea77cc82996c7ebade06387b3da07d7e83a65c84a0ed0a6feefc',evidence.mouse.MANIFEST)
    audit=span(audit,"assert len(old_rows) == len(old_manifest['files']) == 190",
        "assert new_rows['ventium/rtl/core/core_cacheinv_local.svh']",
        "assert len(old_rows) == len(old_manifest['files']) == 192\nassert set(new_rows)==set(old_rows)\n")
    new_manifest=json.loads((ROOT/SOURCE/'input-manifest.json').read_text())
    changes={r['frozen']:r['sha256'] for r in new_manifest['files'] if r['frozen'] in evidence.export.CHANGES}
    audit=span(audit,'expected_changes=','assert set(changed)',f'expected_changes={changes!r}\n')
    output[SYNTH+'/audit_closed.py']=audit
    output[SYNTH+'/launch_checked.tcl']=original['posted-mouse-synthesis-r1/launch_checked.tcl']
    old=original['posted-mouse-clock-r1/run.py'];text=common(old)
    text=replace(text,"synthesis = root.parent/'posted-mouse-synthesis-r1'",f"synthesis = root.parent/'{SYNTH}'")
    text=replace(text,str(ROOT/'pipe-wait-synthesis-r1'),str(ROOT/'posted-mouse-synthesis-r1'))
    text=replace(text,'1d9d3641ebe12b64f66e4b00f7dccd0da9a5b3c4f4de99d4116257a4cb02d30c',
                 '9354b17d35b1c0cb4a49bf1bcd00cf6e511b8253c5b250b427d10e6764741315')
    text=replace(text,evidence.mouse.MANIFEST,evidence.MANIFEST)
    text=replace(text,evidence.mouse.MODEL,evidence.MODEL)
    clock_guarded(text,old);output[CLOCK+'/run.py']=text
    audit=replace(original['posted-mouse-clock-r1/audit_closed.py'],
        'ventium-posted-mouse-clock-oct16-r1.service','ventium-backing-direction-clock-oct16-r1.service')
    audit=replace(audit,'parent_worst - (-1.350)','parent_worst - (-3.858)')
    audit=replace(audit,'V-result carry cut plus AUX ownership and mouse-wrapper integration',
                 'Only early inactive L1 backing direction; corrected AUX/mouse wrapper unchanged')
    output[CLOCK+'/audit_closed.py']=audit
    output[CLOCK+'/audit.tcl']=original['posted-mouse-clock-r1/audit.tcl']
    for name,text in output.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
    return output


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    pins=evidence.check(ROOT/SOURCE);original={}
    for name,h in TEMPLATES.items():
        p=ROOT/name;assert sha(p)==h;original[name]=p.read_text();pins[str(p)]=h
    for name in ('prepare_backing_direction_timing.py','backing_direction_evidence.py',
                 'prepare_fragment_exact_timing.py','prepare_payload_current_synthesis.py',
                 'prepare_v_result_carry_clock.py'):
        p=Path(__file__).with_name(name).resolve();pins[str(p)]=sha(p)
    output=derive(original)
    assert not (ROOT/RECEIPT).exists() and all(not (ROOT/n).exists() for n in output)
    for name,text in output.items():
        p=ROOT/name;p.parent.mkdir(exist_ok=True)
        with p.open('x') as f:f.write(text)
    data=dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
        template_pins=pins,outputs={str(ROOT/n):sha(ROOT/n) for n in output},
        source_manifest_sha256=evidence.MANIFEST,model_sha256=evidence.MODEL,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (ROOT/RECEIPT).open('x') as f:json.dump(data,f,indent=2)
    print('Matched backing-direction synthesis/clock controllers prepared, not launched.')


if __name__=='__main__':main()
