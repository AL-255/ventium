"""Prepare the guarded 40 MHz branch-address experiment; launch nothing.

The retained controllers' native lifetime, exclusive launcher, resource
admission, watchdog, termination and reaping are byte-identical.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_branch_address_soc as native
import prepare_prefix_opcode_synthesis as templates
from prepare_fragment_exact_timing import replace,sha,span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

DATA=Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve(strict=True)
ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
MANIFEST='f3d9952f0d85d60ce85a85bfec38bb37a939b39a739dc02e6ebde5a6d0297427'
MODEL='0a1f097ee98c816eef72fc432a17fe09e77d7912651c548ad14853512e8edc52'
PARENT_MANIFEST='9e53127a928b0044465174583cb7ed87abc8da1d7644056054d3ceeeb5688bbb'
PARENT_DCP='5c0ee4195b9331cf7eb31b022b86753feecd892cd3cff78cc1448c717b4b6557'

PROOF='''# Current directed and FPU evidence; not inherited metadata passes.
for name in ('branch-address-leaf-r1','branch-address-system-r1',
             'branch-address-controls-r1','branch-address-func-r1',
             'sequences-underflow-r1','cold-underflow-r1','partial-underflow-r1'):
    checked=load_proof(name+'/closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and not checked.get('errors')
    pins.update(load_proof(name+'/started.json')['pins'])
    if name=='branch-address-system-r1':
        assert checked['all_children_reaped'] and len(checked['measurements'])==560
        assert sum(r['records'] for r in checked['measurements'] if r['model']=='candidate')==77420
    if name=='branch-address-func-r1':
        assert len(checked['rows'])==108 and all(r['passed'] and r['actual_wait'] and
            r['affinity_verified'] and r['native_worker_exit']==0 for r in checked['rows'])
    if name=='branch-address-controls-r1':
        assert len(checked['rows'])==5 and all(r['passed'] and len(r['rows'])==6 for r in checked['rows'])
    if name=='sequences-underflow-r1':
        assert len(checked['rows'])==4
        assert all(r['passed'] and r['cases']==8448 and r['records']==266880 for r in checked['rows'])
        assert len({r['records_sha256'] for r in checked['rows']})==1
    if name=='partial-underflow-r1':
        assert checked['implementations']['candidate']['failures']==0
        assert checked['implementations']['control']['failures']==720
verify=load_proof('branch-address-core-r1/verify-closed.json')
assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']
assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
assert len(verify['deltas'])==20 and all(r['same_records'] for r in verify['deltas'])
# No waived canonical gate, newly strict stack comparison or standard-suite
# pass. No buffered metadata RTL or previous timing failure is inherited.
'''


def common(text):
    return (text.replace('prefix-payload-','branch-address-')
        .replace('prefix_payload_timing','branch_address_shape_timing')
        .replace('build_prefix_payload_soc','build_branch_address_soc')
        .replace('ventium-branch-address-synth-oct14-r1','ventium-branch-address-synth-oct15-r1')
        .replace('ventium-branch-address-clock-oct14-r1','ventium-branch-address-clock-oct15-r1')
        .replace('baseline_gameplay_ipc=0.51186266,baseline_window=[1700065237,1800065237]',
                 'baseline_gameplay_ipc=0.50520554,baseline_window=[5600065237,5700065237]'))


def derive(original,changes):
    assert set(changes)=={'ventium/'+n for n in native.CHANGES}
    outputs={};old=original['prefix-payload-synthesis-r1/run.py'];text=common(old)
    text=replace(text,'Measure equivalent register-prefix memory-payload isolation; no route or deployment.',
        'Measure early branch address plus three FPREM repairs; no route or deployment.')
    text=replace(text,"prepared['parent_model']==native.PARENT_MODEL and prepared['functional_corpus_passed']",
        "prepared['parent_model']==native.PARENT_MODEL and prepared['statistics']['private_functional_passes']==108")
    text=span(text,'funcproof=proof/',"pc=load_proof('branch-address-soc-r1/build-closed.json')",PROOF)
    text=replace(text,"cmroot=root.parent/'branch-address-soc-r1/coremark'",
                      "cmroot=root.parent/'branch-address-soc-r1/coremark-r1'")
    text=span(text,'    rationale=','    generic_gate=',
        "    rationale='Remove late pairing eligibility from the raw branch address payload only. Checked descriptors, permissions and commit remain unchanged. Carry numeric, operand-exception and exact-underflow FPREM repairs omitted by the retained timing parent. Four source files; no defines, clock, cache or transport change. Extracted source/mutation tests, complete cold branch A/B/QEMU comparisons, functional/system controls and unchanged short cold CoreMark clocks. Measure combined area/frequency against retained 36.591166892 MHz parent; no isolated address-cut gain claimed. Canonical red; no route or physical acceptance.',\n")
    text=replace(text,"generic_gate='FUNC 108/108 with existing masks; cycle/fault gates remain red; CPU lint only, not full SoC or suite'",
        "generic_gate='Private reference 108/108 with existing policy; canonical native exit 2; 20 parent-identical cycle streams, not band passes; CPU-hierarchy lint only'")
    guarded(text,old)
    a,b='host = available()\n',"(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)]==old[old.index(a):old.index(b)]
    outputs['branch-address-synthesis-r1/run.py']=text
    old=original['prefix-payload-clock-r1/run.py'];text=common(old)
    text=replace(text,str(DATA/'fast-segment-synthesis-r2'),str(DATA/'prefix-payload-synthesis-r1'))
    text=replace(text,'8d41c9b7cbeb543c9d72b253e53ca15de204200229d4517efe73b2d6ca7176b0',PARENT_DCP)
    clock_guarded(text,old);outputs['branch-address-clock-r1/run.py']=text
    text=common(original['prefix-payload-synthesis-r1/audit_closed.py'])
    for a,b in (('fast-segment-synthesis-r2','prefix-payload-synthesis-r1'),
                ('fast-segment-fpga-r1','prefix-payload-fpga-r1')):
        text=replace(text,str(DATA/a),str(DATA/b))
    text=replace(text,'d4122ecbed950b845654bec8060fa83b96213f07b373b002604704cea06b6f7e',PARENT_MANIFEST)
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(changes)+'\n')
    text=replace(text,'one-include prefix-payload transfer','four-file branch address and FPREM transfer')
    outputs['branch-address-synthesis-r1/audit_closed.py']=text
    text=common(original['prefix-payload-clock-r1/audit_closed.py'])
    outputs['branch-address-clock-r1/audit_closed.py']=replace(text,'(-3.189)','(-2.329)')
    outputs['branch-address-clock-r1/audit.tcl']=original['prefix-payload-clock-r1/audit.tcl']
    for name,text in outputs.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
    return outputs


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root==ROOT and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    source=root/'branch-address-fpga-r1';assert sha(source/'input-manifest.json')==MANIFEST
    manifest=json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256']==PARENT_MANIFEST
    assert sha(root/'branch-address-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted')==MODEL
    changes={n:sha(source/n) for n in manifest['changed_parent_payloads']}
    for n in changes:
        assert native.transform(n.removeprefix('ventium/'),(DATA/'prefix-payload-fpga-r1'/n).read_text())==(source/n).read_text()
    original,pins={},{}
    for n,digest in templates.TEMPLATES.items():
        p=DATA/n;assert sha(p)==digest;original[n]=p.read_text();pins[str(p)]=digest
    for module in (native,native.base,native.recipe,native.numeric,native.exceptions,native.underflow,
                   native.underflow.leaf,templates):
        p=Path(module.__file__).resolve();pins[str(p)]=sha(p)
    for p in (Path(__file__),Path(__file__).with_name('prepare_fragment_exact_timing.py'),
              Path(__file__).with_name('prepare_payload_current_synthesis.py'),
              Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(p.resolve())]=sha(p)
    outputs=derive(original,changes);receipt=root/'branch-address-timing-prepared.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in outputs)
    for n,text in outputs.items():
        p=root/n;p.parent.mkdir(parents=True,exist_ok=True)
        with p.open('x') as f:f.write(text)
    with receipt.open('x') as f:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in outputs},
            source_manifest_sha256=MANIFEST,model_sha256=MODEL,canonical_gate_passed=False,
            standard_suite=False,hardware_acceptance=False,fmax_mhz=None,gameplay_ipc=None),f,indent=2)
    print('Guarded branch-address controllers prepared; nothing launched.',flush=True)


if __name__=='__main__':main()
