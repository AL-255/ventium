"""Prepare a matched timing measurement of buffered fetch metadata + FPREM fixes.

Keep the closed parent's native launch/watchdog/reaping and resource admission
byte-identical. Launch nothing here; canonical and physical acceptance stay open.
"""
import argparse
import ast
import json
import os
from pathlib import Path

import build_fetch_metadata_soc as native
import prepare_prefix_opcode_synthesis as templates
from prepare_fragment_exact_timing import replace, sha, span
from prepare_payload_current_synthesis import guarded
from prepare_prime_reg_flags_synthesis import clock_guarded

ROOT=Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X').resolve(strict=True)
MANIFEST='6d57df5328d1c6a2c4b3dc4f1e14a9021378966fa6388ea65af781a94dba3371'
MODEL='e09cd8f84ad449a445c13af01a4c15f47852fc7c26cff63f7792ce8e780ae503'
PARENT_MANIFEST='9e53127a928b0044465174583cb7ed87abc8da1d7644056054d3ceeeb5688bbb'
PARENT_DCP='5c0ee4195b9331cf7eb31b022b86753feecd892cd3cff78cc1448c717b4b6557'

PROOF='''# Recheck this candidate's complete audit, not inherited parent passes.
funcproof=proof/'fetch-metadata-audit.json'
assert sha(funcproof)==native.AUDIT
func=load_proof('fetch-metadata-audit.json')
assert func['passed'] and func['model_sha256']==native.CORE_MODEL
assert func['input_pins']==1454 and func['metadata_vectors']==524288
assert (func['functional_passes'],func['records'],func['v_retirements'])==(108,80800,30132)
assert sorted(func['strict_functional_failures'])==['tx_regform','tx_regform2','tx_stack']
assert (func['system_records'],func['system_v'])==(30141,5487)
assert (func['boundary_records'],func['boundary_v'])==(6096,264)
assert (func['canonical_pass'],func['canonical_fail'],func['identical_cycle_streams'])==(7,101,20)
assert not func['standard_suite'] and not func['hardware_acceptance'] and func['gameplay_ipc'] is None
pins.update(func['pins'])
for unit,expected in func['owners'].items():
    actual=dict(line.split('=',1) for line in subprocess.check_output([
        'systemctl','--user','show',unit,'-pSubState','-pInvocationID','-pMainPID','-pExecMainStatus'],text=True).splitlines())
    assert actual==expected and actual['MainPID']=='0'
fp=proof.parent/'ventium-fprem-sequence.iSZ9BAj4/exception-audit.json'
assert sha(fp)==native.FP_AUDIT and json.loads(fp.read_text())['passed']
pins[str(fp)]=sha(fp)
verify=load_proof('fetch-metadata-core-r1/verify-closed.json')
assert verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']
assert verify['pins_unchanged'] and not verify['masks_or_goldens_or_bands_changed']
assert len(verify['deltas'])==20 and all(r['same_records'] for r in verify['deltas'])
# Finite-CS A/B/self-checks are diagnostics, not new QEMU passes. The
# canonical failures, three strict x87 failures and FPREM UM=0 issue remain.
'''


def common(text):
    return (text.replace('prefix-payload-','fetch-metadata-')
        .replace('prefix_payload_timing','fetch_metadata_timing')
        .replace('build_prefix_payload_soc','build_fetch_metadata_soc')
        .replace('ventium-fetch-metadata-synth-oct14-r1','ventium-fetch-metadata-synth-oct15-r1')
        .replace('ventium-fetch-metadata-clock-oct14-r1','ventium-fetch-metadata-clock-oct15-r1')
        .replace('baseline_gameplay_ipc=0.51186266,baseline_window=[1700065237,1800065237]',
                 'baseline_gameplay_ipc=0.50520554,baseline_window=[5600065237,5700065237]'))


def derive(original,changes):
    assert set(changes)=={'ventium/'+n for n in native.CHANGES}
    outputs={}
    old=original['prefix-payload-synthesis-r1/run.py'];text=common(old)
    text=replace(text,'Measure equivalent register-prefix memory-payload isolation; no route or deployment.',
        'Measure buffered fetch metadata with both FPREM repairs; no route or deployment.')
    text=span(text,'funcproof=proof/',"pc=load_proof('fetch-metadata-soc-r1/build-closed.json')",PROOF)
    text=replace(text,"cmroot=root.parent/'fetch-metadata-soc-r1/coremark'",
                      "cmroot=root.parent/'fetch-metadata-soc-r1/coremark-r1'")
    text=span(text,'    rationale=','    generic_gate=',
        "    rationale='Separate buffered fetch/fault metadata from live semantic bytes using the same decoder. Include both qualified FPREM repair files omitted by the older timing parent. Three exact source changes, no define/cache/transport/clock change. Actual-wiring miter and negative controls, 108-program private-reference corpus, complete replay, system/boundary diagnostics and short cold CoreMark controls. Compare total corrected-candidate area/timing against retained 36.591166892 MHz parent; no isolated gain attribution to metadata. Canonical remains failed. No route, standard-suite or physical acceptance inherited.',\n")
    text=replace(text,
        "generic_gate='FUNC 108/108 with existing masks; cycle/fault gates remain red; CPU lint only, not full SoC or suite'",
        "generic_gate='Private reference 108/108, strict 105/108; canonical 7 PASS/101 FAIL, native exit 2; 20 cycle streams identical, not band passes; CPU-hierarchy lint only'")
    guarded(text,old)
    a,b='host = available()\n',"(root/'once').mkdir()"
    assert text[text.index(a):text.index(b)]==old[old.index(a):old.index(b)]
    outputs['fetch-metadata-synthesis-r1/run.py']=text

    old=original['prefix-payload-clock-r1/run.py'];text=common(old)
    text=replace(text,str(ROOT/'fast-segment-synthesis-r2'),str(ROOT/'prefix-payload-synthesis-r1'))
    text=replace(text,'8d41c9b7cbeb543c9d72b253e53ca15de204200229d4517efe73b2d6ca7176b0',PARENT_DCP)
    clock_guarded(text,old)
    outputs['fetch-metadata-clock-r1/run.py']=text

    text=common(original['prefix-payload-synthesis-r1/audit_closed.py'])
    for a,b in (('fast-segment-synthesis-r2','prefix-payload-synthesis-r1'),
                ('fast-segment-fpga-r1','prefix-payload-fpga-r1')):
        text=replace(text,str(ROOT/a),str(ROOT/b))
    text=replace(text,'d4122ecbed950b845654bec8060fa83b96213f07b373b002604704cea06b6f7e',PARENT_MANIFEST)
    text=span(text,'expected_changes=','assert set(changed)','expected_changes='+repr(changes)+'\n')
    text=replace(text,'one-include prefix-payload transfer','three-file fetch metadata and FPREM transfer')
    outputs['fetch-metadata-synthesis-r1/audit_closed.py']=text
    text=common(original['prefix-payload-clock-r1/audit_closed.py'])
    outputs['fetch-metadata-clock-r1/audit_closed.py']=replace(text,'(-3.189)','(-2.329)')
    outputs['fetch-metadata-clock-r1/audit.tcl']=original['prefix-payload-clock-r1/audit.tcl']
    for name,text in outputs.items():
        if name.endswith('.py'):ast.parse(text,filename=name)
    return outputs


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root==ROOT and Path(os.environ['TMPDIR']).resolve()==ROOT.parent
    source=root/'fetch-metadata-fpga-r1'
    assert sha(source/'input-manifest.json')==MANIFEST
    manifest=json.loads((source/'input-manifest.json').read_text())
    assert manifest['parent_manifest_sha256']==PARENT_MANIFEST
    assert sha(root/'fetch-metadata-soc-r1/obj1-speed-q16-parentpolicy/ao486sim_board_posted')==MODEL
    changes={name:sha(source/name) for name in manifest['changed_parent_payloads']}
    assert set(changes)=={'ventium/'+n for n in native.CHANGES}
    for name in changes:
        assert native.transform(name.removeprefix('ventium/'),(root/'prefix-payload-fpga-r1'/name).read_text())==(source/name).read_text()
    original,pins={},{}
    for name,digest in templates.TEMPLATES.items():
        path=root/name;assert sha(path)==digest
        original[name]=path.read_text();pins[str(path)]=digest
    for module in (native,native.base,native.recipe,native.numeric,native.exceptions,templates):
        path=Path(module.__file__).resolve();pins[str(path)]=sha(path)
    for path in (Path(__file__),Path(__file__).with_name('prepare_fragment_exact_timing.py'),
                 Path(__file__).with_name('prepare_payload_current_synthesis.py'),
                 Path(__file__).with_name('prepare_prime_reg_flags_synthesis.py')):
        pins[str(path.resolve())]=sha(path)
    outputs=derive(original,changes);receipt=root/'fetch-metadata-timing-prepared.json'
    assert not receipt.exists() and all(not (root/n).exists() for n in outputs)
    for name,text in outputs.items():
        path=root/name;path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('x') as stream:stream.write(text)
    with receipt.open('x') as stream:
        json.dump(dict(controllers_generated_not_launched=True,unchanged_guard_lifecycle=True,
            template_pins=pins,outputs={str(root/n):sha(root/n) for n in outputs},
            source_manifest_sha256=MANIFEST,model_sha256=MODEL,canonical_gate_passed=False,
            standard_suite=False,hardware_acceptance=False,fmax_mhz=None,gameplay_ipc=None),stream,indent=2)
    print('Guarded fetch-metadata controllers prepared; nothing launched.',flush=True)


if __name__=='__main__':main()
