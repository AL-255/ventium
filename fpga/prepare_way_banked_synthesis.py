"""Prepare matched way-banked/fetch-page synthesis with unchanged guard policy."""
import argparse
import ast
import json
import os
from pathlib import Path

import build_way_banked_soc as native
from prepare_fragment_exact_timing import replace,sha,span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

SCRATCH=Path('/home/yukidama/external/tmp').resolve(strict=True)
ROOT=SCRATCH/'ventium-data-size.v2HaTO2X'
MANIFEST='8f4cf7b06c4368cf888300300513a2835fe7bd678e192b48839bebdb00fe1523'
MODEL='810fca8a8f27298f190274a85d8bec7d6ccf785347edfaa0316f4662a43f4719'
PARENT_MANIFEST='296ff7367ef6af0324c47a09615f09f2c02a700a3de411efc617f598c03c001b'
PARENT_DCP='8b312897be7efeee639cf4f85856e081347f13e1dd8a608dc3843986933443a1'
CHANGES={
    'ventium/rtl/core/core.sv':'4606df0a39c042d5ff9cbe65c80b4841001643404bee765db9ee49384f353291',
    'ventium/rtl/mem/ven_l1d.sv':'62d3332d4d044efe022acce33eaa99b16e9a36da7a43e4afeda0b0265baeb3f3'}
TEMPLATES={
    'fp-compare-synthesis-r1/run.py':'c28910854fbd0efb18e16c0752b35b16f796934a03562e26e7ba339fdc696cb2',
    'fp-compare-synthesis-r1/audit_closed.py':'dfd7a3daa9df8c430f8250359a58a6aa124cce15fbfd90cdc60818cb85c42cc8',
    'fp-compare-clock-r1/run.py':'067d854c8c1cf5c0ab379bc31f2655ca716ff7176f43571db9cd0f7e98372f08',
    'fp-compare-clock-r1/audit_closed.py':'14f9457c708f2fc65a089899ee7ac79f13036d37e52092bc74f8cb13de94d4d5',
    'fp-compare-clock-r1/audit.tcl':'a48c6daa74f3ecd244bc97f8070ada34ee9ce3851ae727583036311ad4842666'}


def common(text):
    text=text.replace('fp-compare-','way-banked-')
    text=text.replace('fp_compare_timing','way_banked_timing')
    return text.replace('build_fp_compare_soc','build_way_banked_soc')


def baseline(text):
    return replace(text,'baseline_gameplay_ipc=0.5048994,baseline_window=[800065237,900065237]',
        'baseline_gameplay_ipc=0.51027341,baseline_window=[1200065237,1300065237]')


def derive(original):
    outputs={}
    old=original['fp-compare-synthesis-r1/run.py']
    text=baseline(common(old))
    text=replace(text,'20ec2c93635ad2548b1977e30065e64f910a3630f545385e9fcc2e48bdf36732',
        'bf17a9053431218ff69194286ab1a91ed3434196ec51e2d78ea9cd5e10e60c96')
    text=replace(text,'Measure parallel next-line tags and direct FP invalid classification; no route or deployment.',
        'Measure explicit tag-way RAM inference and the equivalent fetch-page cut; no route or deployment.')
    text=replace(text,"pc=load_proof('way-banked-soc-r1/build-closed.json')",
        "fetch=load_proof('way-banked-fetch-r1/audit.json')\n"
        "assert fetch['passed'] and fetch['cases']==22 and fetch['qemu_comparisons']==88\n"
        "assert fetch['native_rtl_executions']==176 and fetch['candidate_records']==21832\n"
        "assert fetch['candidate_v_retirements']==4968 and fetch['probe_witnesses']==44\n"
        "pins.update(fetch['artifacts'])\n"
        "pc=load_proof('way-banked-soc-r1/build-closed.json')")
    text=span(text,'    rationale=','    generic_gate=',
        "    rationale='Restore distributed tag RAM using two explicit way banks; shorten the late fetch-fault page/crossing arithmetic with a proved 13-bit offset sum. Target the measured 32.405457079 MHz, 105-level integer path and the confirmed 5120-tag-FF inference regression. Exactly two RTL files, unchanged cycles/profile/clocks/constraints, no guest patches. Full-cache equivalence and OOC RAM inference, all-input arithmetic proof, whole-core fetch/fault/private-QEMU tests and short CoreMark controls retained. Measure whole-chip area and Fmax; canonical, full-suite and physical acceptance remain open.',\n")
    guarded(text,old)
    first,last='host = available()\n',"(root/'once').mkdir()"
    assert text[text.index(first):text.index(last)]==old[old.index(first):old.index(last)]
    outputs['way-banked-synthesis-r1/run.py']=text

    old=original['fp-compare-clock-r1/run.py']
    text=baseline(common(old))
    text=replace(text,str(ROOT/'window-current-synthesis-r2'),str(ROOT/'fp-compare-synthesis-r1'))
    text=replace(text,'4df9848c06b6423762546bbe6894ecdaba554446f020cd0f24ebd25814df6c14',PARENT_DCP)
    clock_guarded(text,old)
    outputs['way-banked-clock-r1/run.py']=text

    text=common(original['fp-compare-synthesis-r1/audit_closed.py'])
    text=replace(text,str(ROOT/'window-current-synthesis-r2'),str(ROOT/'fp-compare-synthesis-r1'))
    text=replace(text,str(ROOT/'window-current-fpga-r1'),str(ROOT/'fp-compare-fpga-r1'))
    text=replace(text,'09160fa65d1b67dcfd9bc263715c5b73475c04410991a3941e651f3eb59fa7c8',PARENT_MANIFEST)
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(CHANGES)+'\n')
    text=replace(text,'two-file next-tag/FP-classifier transfer','two-file way-bank/fetch-page transfer')
    outputs['way-banked-synthesis-r1/audit_closed.py']=text
    text=common(original['fp-compare-clock-r1/audit_closed.py'])
    outputs['way-banked-clock-r1/audit_closed.py']=replace(text,'(-5.277)','(-5.859)')
    outputs['way-banked-clock-r1/audit.tcl']=original['fp-compare-clock-r1/audit.tcl']
    for name,text in outputs.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
    return outputs


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root==ROOT and Path(os.environ['TMPDIR']).resolve()==SCRATCH
    source=root/'way-banked-fpga-r1'
    assert sha(source/'input-manifest.json')==MANIFEST
    manifest=json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256']==PARENT_MANIFEST
    assert set(manifest['changed_parent_payloads'])==set(CHANGES)
    assert sha(root/'way-banked-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted')==MODEL
    for name,digest in CHANGES.items():
        assert sha(source/name)==digest
        assert native.transform(name.removeprefix('ventium/'),(root/'fp-compare-fpga-r1'/name).read_text())==(source/name).read_text()
    original,pins={},{}
    for name,digest in TEMPLATES.items():
        path=ROOT/name;assert sha(path)==digest
        original[name]=path.read_text();pins[str(path)]=digest
    for p in (Path(__file__),Path(native.__file__),native.original,Path(native.tags.__file__),
              Path(native.fetch.__file__),Path(native.fetch.original.__file__),
              Path(__file__).with_name('prepare_fragment_exact_timing.py'),
              Path(__file__).with_name('prepare_payload_current_synthesis.py'),
              Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(p.resolve())]=sha(p)
    outputs=derive(original);receipt=root/'way-banked-timing-prepared.json'
    assert not receipt.exists() and all(not (root/name).exists() for name in outputs)
    for name,text in outputs.items():
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('x') as stream:stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in outputs},
            source_manifest_sha256=MANIFEST,model_sha256=MODEL,canonical_gate_passed=False,
            standard_suite=False,hardware_acceptance=False,fmax_mhz=None,gameplay_ipc=None),stream,indent=2)
    print('Guarded way-bank/fetch-page controllers prepared; nothing launched.',flush=True)


if __name__=='__main__':main()
