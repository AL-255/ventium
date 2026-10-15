"""Prepare matched, guarded synthesis of the pair/next arbitration cofactor.

Native launch, memory/disk admission, watchdog, ownership and reaping remain
byte-identical to the closed parent. No route/deploy or canonical waiver.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_pair_next_disjoint_soc as native
import prepare_prefix_opcode_synthesis as templates
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

ROOT=Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve(strict=True)
MANIFEST='cc27887f48bb6ff758503f11b79e7ea68c773718fe8357aea95323fb36bc462b'
MODEL='b542e94d172defa3528ef0e2faf80a636a5072aa99e63d6ab6ff56335acba2a2'
PARENT_MANIFEST='9e53127a928b0044465174583cb7ed87abc8da1d7644056054d3ceeeb5688bbb'
PARENT_DCP='5c0ee4195b9331cf7eb31b022b86753feecd892cd3cff78cc1448c717b4b6557'
AUDIT='4c12fa6a8df888db06173157fc8e03bce0414b311a6c924a743e728d9b85e733'

PROOF='''# New candidate evidence, not inherited parent/fetch-candidate passes.
assert func['authenticated_input_replay'] and not func['candidate_fresh_qemu']
assert func['pending_translation']==dict(cases=36,latencies=[0,7],comparisons=72,
    complete_qemu_comparisons=144,candidate_records=15840,first_v_pairs=72,cycle_delta=0)
leaf=load_proof('pair-next-disjoint-leaf-r6/closed.json')
assert sha(proof/'pair-next-disjoint-leaf-r6/closed.json')=='2f052911c189b5c0b0d29178b17d09c684d3969664ebd378342197e49af87dd9'
assert leaf['passed'] and leaf['pins_unchanged'] and not leaf['errors']
assert [(r['label'],r['native_exit']) for r in leaf['rows']]==[
    ('generic',0),('disjoint',0),('conflict-negative',1)]
assert leaf['contract_filter'] is None and leaf['legal_domain_equivalence']
pins.update(leaf['pins'])
for row in leaf['native']:
    path=proof/'pair-next-disjoint-leaf-r6'/(row['label']+'.log')
    assert sha(path)==row['log_sha256'] and row['actual_wait']
    pins[str(path)]=sha(path)
for suffix,count in (('load',288),('store',288),('coldalias',144),('fp',16)):
    folder=proof/('pair-next-disjoint-'+suffix+'-r1')
    checked=load_proof(str(folder.relative_to(proof)/'closed.json'))
    started=load_proof(str(folder.relative_to(proof)/'started.json'))
    assert checked['passed'] and checked['pins_unchanged'] and not checked['errors']
    assert len(checked['measurements'])==count
    assert started['models']['candidate']==str(core/'obj/tb_ventium')
    pins.update(started['pins'])
    for path in folder.rglob('*'):
        if path.is_file():pins[str(path)]=sha(path)
held=load_proof('pair-next-disjoint-held-r1/result.json')
assert held['passed'] and held['inputs_unchanged'] and not held['errors'] and len(held['cases'])==48
pins.update(load_proof('pair-next-disjoint-held-r1/inputs.json'))
verify=load_proof('pair-next-disjoint-core-r1/verify-closed.json')
assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']
assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
assert len(verify['deltas'])==20 and all(r['same_records'] for r in verify['deltas'])
# Canonical failure and the independent historical finite-CS oracle issue
# remain open. Neither is relabelled by this diagnostic synthesis.
'''


def common(text):
    return (text.replace('prefix-payload-','pair-next-disjoint-')
        .replace('prefix_payload_timing','pair_next_disjoint_timing')
        .replace('build_prefix_payload_soc','build_pair_next_disjoint_soc')
        .replace('pair-next-disjoint-synthesis-r1','pair-next-disjoint-synthesis-r2')
        .replace('pair-next-disjoint-timing-prepared.json','pair-next-disjoint-timing-prepared-r2.json')
        .replace('ventium-pair-next-disjoint-synth-oct14-r1','ventium-pair-next-disjoint-synth-oct15-r2')
        .replace('ventium-pair-next-disjoint-clock-oct14-r1','ventium-pair-next-disjoint-clock-oct15-r2')
        .replace('baseline_gameplay_ipc=0.51186266,baseline_window=[1700065237,1800065237]',
                 'baseline_gameplay_ipc=0.50520554,baseline_window=[5600065237,5700065237]'))


def derive(original,changes):
    result={}
    old=original['prefix-payload-synthesis-r1/run.py']
    text=common(old)
    text=replace(text,'Measure equivalent register-prefix memory-payload isolation; no route or deployment.',
        'Measure checked pair/next arbitration exclusion; no route or deployment.')
    text=replace(text,'e16799c98385d94ddae7d4cb7296a56cf207ec0f3b43110058a0d03d841c02e8',AUDIT)
    text=span(text,"fault=load_proof('pair-next-disjoint-env-fault-r1/closed.json')",
              "pc=load_proof('pair-next-disjoint-soc-r1/build-closed.json')",PROOF)
    text=replace(text,"cmroot=root.parent/'pair-next-disjoint-soc-r1/coremark'",
                      "cmroot=root.parent/'pair-next-disjoint-soc-r1/coremark-r1'")
    text=span(text,'    rationale=','    generic_gate=',
        "    rationale='Remove only the redundant next-read lookup veto from pair-bank admission in the statically qualified core client. Preserve idle V admission during U translation. Three exact source changes, no feature, cache, transport or clock change. Full-L1 unfiltered miter, explicit conflict negative control, cold-U-translation state/cycle checks, 108-program same-input replay and both short cold CoreMark CRC controls pass. Compare against the retained 36.591166892 MHz parent with the same logic-only mapper. Canonical remains FAIL; no routed, full-suite or physical acceptance is inherited.',\n")
    guarded(text,old)
    a,b='host = available()\n',"(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)]==old[old.index(a):old.index(b)]
    result['pair-next-disjoint-synthesis-r2/run.py']=text

    old=original['prefix-payload-clock-r1/run.py']
    text=common(old)
    text=replace(text,str(ROOT/'fast-segment-synthesis-r2'),str(ROOT/'prefix-payload-synthesis-r1'))
    text=replace(text,'8d41c9b7cbeb543c9d72b253e53ca15de204200229d4517efe73b2d6ca7176b0',PARENT_DCP)
    clock_guarded(text,old)
    result['pair-next-disjoint-clock-r2/run.py']=text

    text=common(original['prefix-payload-synthesis-r1/audit_closed.py'])
    for oldname,newname in (('fast-segment-synthesis-r2','prefix-payload-synthesis-r1'),
                            ('fast-segment-fpga-r1','prefix-payload-fpga-r1')):
        text=replace(text,str(ROOT/oldname),str(ROOT/newname))
    text=replace(text,'d4122ecbed950b845654bec8060fa83b96213f07b373b002604704cea06b6f7e',PARENT_MANIFEST)
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(changes)+'\n')
    text=replace(text,'one-include prefix-payload transfer','three-file pair/next arbitration transfer')
    result['pair-next-disjoint-synthesis-r2/audit_closed.py']=text
    text=common(original['prefix-payload-clock-r1/audit_closed.py'])
    result['pair-next-disjoint-clock-r2/audit_closed.py']=replace(text,'(-3.189)','(-2.329)')
    result['pair-next-disjoint-clock-r2/audit.tcl']=original['prefix-payload-clock-r1/audit.tcl']
    for name,text in result.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',required=True,type=Path)
    root=parser.parse_args().root.resolve(strict=True)
    assert __debug__ and root==ROOT and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    source=root/'pair-next-disjoint-fpga-r1'
    assert sha(source/'input-manifest.json')==MANIFEST
    manifest=json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256']==PARENT_MANIFEST
    assert sha(root/'pair-next-disjoint-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted')==MODEL
    changes={name:sha(source/name) for name in manifest['changed_parent_payloads']}
    assert set(changes)=={'ventium/'+n for n in native.CHANGES}
    for name in changes:
        assert native.transform(name.removeprefix('ventium/'),(root/'prefix-payload-fpga-r1'/name).read_text())==(source/name).read_text()
    original,pins={},{}
    for name,digest in templates.TEMPLATES.items():
        path=root/name
        assert sha(path)==digest
        original[name]=path.read_text();pins[str(path)]=digest
    for path in (Path(__file__),Path(native.__file__),native.original,Path(native.recipe.__file__),
                 Path(templates.__file__),Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py'),
                 Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(path.resolve())]=sha(path)
    outputs=derive(original,changes)
    receipt=root/'pair-next-disjoint-timing-prepared-r2.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in outputs)
    for name,text in outputs.items():
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('x') as stream:stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in outputs},
            source_manifest_sha256=MANIFEST,model_sha256=MODEL,canonical_gate_passed=False,
            standard_suite=False,hardware_acceptance=False,fmax_mhz=None,gameplay_ipc=None),stream,indent=2)
    print('Guarded pair/next controllers prepared; nothing launched.',flush=True)


if __name__=='__main__':main()
