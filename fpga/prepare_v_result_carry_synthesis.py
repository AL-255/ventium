"""Prepare one bounded synthesis of the sealed V-result/AUX/mouse candidate.

Keep the closed predecessor's native lifetime and resource guards unchanged.
This is a diagnostic, not route/deployment or canonical acceptance. Relative
to the last synthesis, AUX/mouse is also newly integrated; do not claim an
isolated V-result timing/area gain from that comparison.
"""
import ast
import json
import os
from pathlib import Path

import freeze_v_result_carry_rk_candidate as candidate
from prepare_fragment_exact_timing import replace,sha,span
from prepare_payload_current_synthesis import guarded

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
MANIFEST='716dab7ee8801e5f865699f2b8619ae881b9d442feb4d59b42399abea758c77e'
PARENT_MANIFEST='d655cc8bf1dcea77cc82996c7ebade06387b3da07d7e83a65c84a0ed0a6feefc'
TEMPLATES={
 'pipe-wait-synthesis-r1/run.py':'c727a3e736d1d016da62799126aba5da931d67ab7aa8383c9ffe8a8c04a8d01d',
 'pipe-wait-synthesis-r1/audit_closed.py':'b8bcd03f39a984b4e7e35f44567ba8ed59fd282a4614277d739842cd3f19e32a',
}
PROOF='''import sys
sys.path.insert(0,str(repo/'fpga'))
import build_v_result_carry_soc as native
prepared=load_proof('v-result-carry-soc-r1/prepared.json')
assert len(prepared['intersecting_rtl_sources'])==102 and prepared['changes']==native.CHANGES
assert prepared['added_defines']==[] and prepared['directed_model']==native.CORE_MODEL
assert prepared['parent_model']==native.PARENT_MODEL and prepared['qualification']=='UNQUALIFIED'
pins.update(prepared['pins'])
core=Path(prepared['directed_core'])
for name in prepared['intersecting_rtl_sources']:
    assert sha(proof/'v-result-carry-soc-r1/source'/name)==sha(core/'candidate'/name)
for name in prepared['changes']:
    before=(Path(prepared['parent'])/'source'/name).read_text()
    assert native.recipe.transform(before,name)==(proof/'v-result-carry-soc-r1/source'/name).read_text()
pins.update(native.evidence(proof,core))
verify=load_proof('v-result-carry-core-r1/verify-closed.json')
assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']
assert len(verify['deltas'])==20 and all(r['same_records'] for r in verify['deltas'])
matched=load_proof('v-result-carry-matched-r1/closed.json')
assert matched['regression_check_passed'] and matched['pins_unchanged'] and not matched['errors']
assert len(matched['rows'])==108 and not matched['masks_or_record_normalization']
pins.update(load_proof('v-result-carry-matched-r1/started.json')['pins'])
pc=load_proof('v-result-carry-soc-r1/build-closed.json')
assert pc['passed'] and pc['native_exit']==0 and pc['inputs_unchanged'] and not pc['errors']
assert pc['binary_sha256']==model and pc['structural_warnings_unchanged'] and pc['structural_debt_count']==98
timing=load_proof('v-result-carry-timing-prepared-r3.json')
assert timing['unchanged_guard_lifecycle'] and timing['controllers_generated_not_launched']
assert timing['source_manifest_sha256']==manifest_sha and timing['model_sha256']==model
pins.update(timing['template_pins']);pins.update(timing['outputs'])
assert all(sha(p)==h for p,h in pins.items())
'''


def derive(original,changed,added):
    old=original['pipe-wait-synthesis-r1/run.py'];text=old
    text=text.replace('pipe-wait-','v-result-carry-')
    text=replace(text,'ventium-v-result-carry-synth-oct15-r1.service','ventium-v-result-carry-synth-oct15-r3.service')
    text=replace(text,'Measure read-owner pipeline wait cofactor; no route or deployment.',
                 'Measure V-result carry cut with current AUX/mouse; no route or deployment.')
    text=replace(text,"manifest['simulator_sha256'] == model", "manifest['simulator_sha256'] is None and manifest['processor_platform_simulator_sha256'] == model")
    text=replace(text,"manifest['variant'] == 'pipe_wait_read_ack_timing'", "manifest['variant'] == 'v_result_carry_aux_mouse_unqualified'")
    text=replace(text,"len(manifest['files']) == 190", "len(manifest['files']) == 192")
    text=span(text,'import sys\n',"cmroot=root.parent/'v-result-carry-soc-r1/coremark-r1'",PROOF)
    text=span(text,'    rationale=','    generic_gate=',
        "    rationale='Remove only the unused carry input from V arithmetic results; flag CF and all execution authority unchanged. Retain AUX ownership and mouse wrapper. Exact 159 hardware defines and 40/100 MHz constraints, complete same-input A-B, cold held/mixed/FP/integer tests and short CoreMark controls. Parent also lacks AUX/mouse, so no isolated timing-gain claim. Canonical still FAIL; no suite, route or board acceptance.',\n")
    text=replace(text,"generic_gate='Private reference 108/108 with existing policy; canonical native exit 2; 20 parent-identical cycle streams, not band passes; CPU-hierarchy lint only'",
        "generic_gate='Canonical native exit 2 retained; 108 complete same-input architectural streams and 20 cycle streams identical; CPU-hierarchy lint only'")
    guarded(text,old)
    a,b='host = available()\n',"(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)]==old[old.index(a):old.index(b)]
    result={'v-result-carry-synthesis-r3/run.py':text}

    old=original['pipe-wait-synthesis-r1/audit_closed.py'];text=old
    text=text.replace('one-file pipeline wait transfer','V-result cut plus current AUX/mouse integration')
    text=text.replace("root.parent / 'pipe-wait-fpga-r1'","root.parent / 'v-result-carry-fpga-r1'")
    text=text.replace("unit = 'ventium-pipe-wait-synth-oct15-r1.service'","unit = 'ventium-v-result-carry-synth-oct15-r3.service'")
    text=text.replace(str(ROOT/'demand-size-synthesis-r1'),str(ROOT/'pipe-wait-synthesis-r1'))
    text=text.replace(str(ROOT/'demand-size-fpga-r1'),str(ROOT/'pipe-wait-fpga-r1'))
    text=replace(text,'d35a4b77598c979affbe91bb3e245587e118d0244e271872527b9555115f5315',PARENT_MANIFEST)
    text=replace(text,"len(new_rows) == len(manifest['files']) == 190","len(new_rows) == len(manifest['files']) == 192")
    text=replace(text,'assert new_rows.keys() == old_rows.keys()',
                 'assert sorted(set(new_rows)-set(old_rows))=='+repr(sorted(added))+'\n'
                 'assert not set(old_rows)-set(new_rows)\n'
                 'assert all(new_rows[n][\'sha256\']==h for n,h in '+repr(added)+'.items())')
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(changed)+'\n')
    anchor="'ventium/rtl/fpu/fpu_srt_div.sv', 'ventium/fpga/clk_div32_40mhz.v')"
    text=replace(text,anchor,"'ventium/rtl/fpu/fpu_srt_div.sv', 'ventium/fpga/clk_div32_40mhz.v',\n"
        "             'ventium/rtl/core/v_pipe.sv', 'flow/src/ven_ps2_mailbox.sv', 'flow/src/ven_ps2_device.sv')")
    result['v-result-carry-synthesis-r3/audit_closed.py']=text
    for name,text in result.items():ast.parse(text,filename=name)
    return result


def main():
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    source=ROOT/'v-result-carry-fpga-r1';parent=ROOT/'pipe-wait-fpga-r1'
    assert sha(source/'input-manifest.json')==MANIFEST and sha(parent/'input-manifest.json')==PARENT_MANIFEST
    current,old=[json.loads((p/'input-manifest.json').read_text()) for p in (source,parent)]
    new_rows={r['frozen']:r['sha256'] for r in current['files']};old_rows={r['frozen']:r['sha256'] for r in old['files']}
    changed={n:new_rows[n] for n in old_rows if new_rows[n]!=old_rows[n]}
    added={n:new_rows[n] for n in new_rows if n not in old_rows}
    assert len(changed)==6 and set(added)=={'flow/src/ven_ps2_device.sv','flow/src/ven_ps2_mailbox.sv'}
    originals={};pins={}
    for name,h in TEMPLATES.items():
        p=ROOT/name;assert sha(p)==h;originals[name]=p.read_text();pins[str(p)]=h
    for p in (Path(__file__),Path(candidate.__file__),Path(candidate.native.__file__),
              Path(__file__).with_name('prepare_fragment_exact_timing.py'),
              Path(__file__).with_name('prepare_payload_current_synthesis.py')):pins[str(p.resolve())]=sha(p)
    outputs=derive(originals,changed,added)
    receipt=ROOT/'v-result-carry-timing-prepared-r3.json'
    assert not receipt.exists() and all(not (ROOT/n).exists() for n in outputs)
    for n,text in outputs.items():
        p=ROOT/n;p.parent.mkdir(parents=True,exist_ok=True)
        with p.open('x') as f:f.write(text)
    with receipt.open('x') as f:json.dump(dict(controllers_generated_not_launched=True,
        unchanged_guard_lifecycle=True,template_pins=pins,outputs={str(ROOT/n):sha(ROOT/n) for n in outputs},
        source_manifest_sha256=MANIFEST,model_sha256=candidate.MODEL,changed_from_last_synthesis=changed,
        added_from_last_synthesis=added,isolated_v_result_gain=False,canonical_gate_passed=False,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None),f,indent=2)
    print('One guarded synthesis controller prepared; not launched.',flush=True)


if __name__=='__main__':main()
