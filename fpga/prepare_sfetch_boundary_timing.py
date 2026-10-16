"""Prepare one matched fetch-stage synthesis and read-only clock audit.

Preserve the closed predecessor's entire CAD lifecycle and measured-growth
resource guards. The explicit cycle-cost diagnostic is not a gate waiver.
Nothing is launched by this preparation command.
"""
import ast
import json
import os
from pathlib import Path

import sfetch_boundary_evidence as evidence
from prepare_fragment_exact_timing import replace,sha,span
from prepare_payload_current_synthesis import guarded as synth_guarded
from prepare_v_result_carry_clock import guarded as clock_guarded

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
SOURCE='sfetch-boundary-fpga-r1'
SYNTH='sfetch-boundary-synthesis-r1'
CLOCK='sfetch-boundary-clock-r1'
RECEIPT='sfetch-boundary-timing-prepared-r1.json'
TEMPLATES={
 'backing-direction-synthesis-r1/run.py':'6c714e31febc4d7c576f0acc6c59c3f48ae5e1af935f6f7fd5e2cb3ef4ac7de7',
 'backing-direction-synthesis-r1/audit_closed.py':'5af9e1811e3d82ec63289ea983910182434aeed1bfb90a03f190851f63e877aa',
 'backing-direction-synthesis-r1/launch_checked.tcl':'725abb0abf9758d6bcec583ef1209b9213797eb371efcf8733d91a0518c200e7',
 'backing-direction-clock-r1/run.py':'95486e6edc0eb4a29e341e83d25a7056272f786cb781fe95c981fb4f687a1792',
 'backing-direction-clock-r1/audit_closed.py':'168cb42114e638eab013eec69b5a64d6d393abed926c57e3942f2ea7efa4055e',
 'backing-direction-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666',
}


def common(text):
    for old,new in (
        ('backing-direction-', 'sfetch-boundary-'),
        ('backing_direction_', 'sfetch_boundary_'),
        ('build_backing_direction_soc', 'build_sfetch_boundary_soc'),
        (evidence.previous.MANIFEST, evidence.MANIFEST),
        (evidence.previous.MODEL, evidence.MODEL),
        ('baseline_gameplay_ipc=0.48146083,baseline_window=[1100065247,1200065247]',
         'baseline_gameplay_ipc=0.49046518,baseline_window=[1600065247,1700065247]'),
    ):
        text=text.replace(old,new)
    return text


def derive(original):
    output={}
    old=original['backing-direction-synthesis-r1/run.py'];text=common(old)
    text=replace(text,'Measure V-result carry cut with current AUX/mouse; no route or deployment.',
                 'Measure boundary-only fetch staging with measured cycle cost; no route or deployment.')
    text=replace(text,'native.recipe.transform(before)','native.recipe.transform(before,name)')
    text=span(text,"verify=load_proof('sfetch-boundary-core-r1/verify-closed.json')",
        "pc=load_proof('sfetch-boundary-soc-r1/build-closed.json')",
        "cycle_pins,cycle_policy=native.cycle_cost_diagnostic(core)\n"
        "pins.update(cycle_pins)\n"
        "assert prepared['cycle_cost']==cycle_policy and cycle_policy['diagnostic_only']\n"
        "assert not cycle_policy['canonical_gate_passed'] and not cycle_policy['cycle_equivalence_passed']\n")
    text=replace(text,"assert [r['ticks'] for r in cm['results']]==[4767218,4753406]\n"
                      "assert all(r['parent_ticks']==r['candidate_ticks'] for r in cm_audit['measurements'])",
        "assert len(cm['results'])==len(cm_audit['measurements'])==2\n"
        "assert [r['parent_ticks'] for r in cm_audit['measurements']]==[4767218,4753406]\n"
        "assert [r['ticks'] for r in cm['results']]==[r['candidate_ticks'] for r in cm_audit['measurements']]\n"
        "assert all(0<=r['clock_cost_percent']<=0.2 for r in cm_audit['measurements'])\n"
        "assert not cm['standard_suite'] and not cm['score_eligible']\n"
        "assert not cm_audit['duration_valid'] and not cm_audit['physical_board']")
    text=span(text,'    rationale=','    generic_gate=',
        "    rationale='Only true page/CS/IP-boundary beats acquire one preparation stage. Interior-16 and fast U/V remain unstaged. Exact two-file transfer, complete source closure, same corrected wrapper/159 defines/mapper/40 MHz constraint. Directed worst-boundary cost is still +34.88%; short CoreMark controls must remain within +0.2% clocks. Canonical and original cycle-equivalence gates remain failed. Timing diagnosis only; no route, suite or FPGA acceptance.',\n")
    text=span(text,'    generic_gate=','    hardware_acceptance=',
        "    generic_gate='Canonical native exit 2 retained; private-reference 108/108 under existing masks. 19 identical cycle streams and mb_brrandom +21 clocks, identical retirement identity. Strict CPU lint only.',\n")
    synth_guarded(text,old)
    a,b='host = available()\n',"(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)]==old[old.index(a):old.index(b)]
    output[SYNTH+'/run.py']=text

    audit=common(original['backing-direction-synthesis-r1/audit_closed.py'])
    manifest=json.loads((ROOT/SOURCE/'input-manifest.json').read_text())
    changes={r['frozen']:r['sha256'] for r in manifest['files'] if r['frozen'] in evidence.export.CHANGES}
    assert sorted(changes)==evidence.export.CHANGES
    audit=span(audit,'expected_changes=','assert set(changed)',f'expected_changes={changes!r}\n')
    audit=replace(audit,'V-result cut plus current AUX/mouse integration','boundary-only fetch stage with unchanged wrapper')
    output[SYNTH+'/audit_closed.py']=audit
    output[SYNTH+'/launch_checked.tcl']=original['backing-direction-synthesis-r1/launch_checked.tcl']

    old=original['backing-direction-clock-r1/run.py'];text=common(old)
    text=span(text,'    generic_gate=','    hardware_acceptance=',
        "    generic_gate='Canonical and cycle-equivalence FAIL retained; private-reference 108/108, 19 identical cycle streams and one +21-clock diagnostic. CPU lint only, not full SoC or suite.',\n")
    clock_guarded(text,old)
    a,b='host = available()\n',"(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)]==old[old.index(a):old.index(b)]
    output[CLOCK+'/run.py']=text
    audit=common(original['backing-direction-clock-r1/audit_closed.py'])
    audit=replace(audit,'Only early inactive L1 backing direction; corrected AUX/mouse wrapper unchanged',
                 'Only true-boundary fetch preparation stage; corrected AUX/mouse wrapper unchanged')
    output[CLOCK+'/audit_closed.py']=audit
    output[CLOCK+'/audit.tcl']=original['backing-direction-clock-r1/audit.tcl']
    for name,text in output.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
    return output


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    pins=evidence.check(ROOT/SOURCE);original={}
    for name,digest in TEMPLATES.items():
        p=ROOT/name;assert sha(p)==digest;original[name]=p.read_text();pins[str(p)]=digest
    for name in ('prepare_sfetch_boundary_timing.py','sfetch_boundary_evidence.py',
                 'prepare_fragment_exact_timing.py','prepare_payload_current_synthesis.py',
                 'prepare_v_result_carry_clock.py'):
        p=Path(__file__).with_name(name).resolve();pins[str(p)]=sha(p)
    output=derive(original)
    assert not (ROOT/RECEIPT).exists() and all(not (ROOT/n).exists() for n in output)
    for name,text in output.items():
        p=ROOT/name;p.parent.mkdir(exist_ok=True)
        with p.open('x') as stream:stream.write(text)
    data=dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
        template_pins=pins,outputs={str(ROOT/n):sha(ROOT/n) for n in output},
        source_manifest_sha256=evidence.MANIFEST,model_sha256=evidence.MODEL,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with (ROOT/RECEIPT).open('x') as stream:json.dump(data,stream,indent=2)
    print('Matched boundary-stage synthesis/clock controllers prepared, not launched.')


if __name__=='__main__':main()
