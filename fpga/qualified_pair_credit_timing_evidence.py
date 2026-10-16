"""Admit a diagnostic timing measurement, never deployment or acceptance.

Recheck the complete sealed evidence closure. Two exact historical controller
sources have documented archives after reference-profile promotion; substitute
only those identities, and also pin their current maintained files. Do not
rewrite historical receipts or waive any other drift.
"""
import hashlib
import json
from pathlib import Path
import sys

import freeze_qualified_pair_credit_rk_candidate as export

ROOT=export.native.ROOT
REPO=Path(__file__).resolve().parents[1]
MANIFEST='ad6b7c19643faf50a98d12d96d0edaa018716566d64bd0d498566156570b7964'
MODEL=export.MODEL
CORE_MODEL=export.native.CORE_MODEL
VARIANT=export.VARIANT
SOURCE=ROOT/'qualified-pair-credit-fpga-r1'
ALIASES={
    str(REPO/'verif/verify.sh'):(
        '7c65a13dc91de4bf94db923b2b91053347a6a12b5133964aa748fca8cddc282a',
        ROOT/'qualified-reference-profile-r1/prior-verify.sh'),
    str(REPO/'verif/qemu-trace/run_qualified_profile_gate.py'):(
        'dd471f4eedaf59b6bd10a970df34d1709785b3cebb9cd1e8745e6edce60799c9',
        ROOT/'qualified-reference-profile-r1/gate-r1/run_qualified_profile_gate-observed.py'),
}


def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def historical(pins):
    result={}
    for name,digest in pins.items():
        if name in ALIASES and digest==ALIASES[name][0]:
            archived=ALIASES[name][1]
            assert sha(archived)==digest,'historical source archive drift'
            result[str(archived)]=digest
            result[name]=sha(name)
        else:result[name]=digest
    return result


def check(source=SOURCE):
    source=Path(source).resolve(strict=True)
    assert source==SOURCE and sha(source/'input-manifest.json')==MANIFEST
    pins={}
    def merge(values):
        for name,digest in historical(values).items():
            assert name not in pins or pins[name]==digest,('conflicting input identity',name)
            pins[name]=digest
    def load(path):
        path=Path(path);pins[str(path)]=sha(path)
        return json.loads(path.read_text())
    receipt=load(source/'freeze-receipt.json')
    manifest=load(source/'input-manifest.json')
    prior=ROOT/'raw-prime-storage-fpga-r1'
    assert sha(prior/'input-manifest.json')==export.PARENT
    old=load(prior/'input-manifest.json')
    assert receipt['preprocessing_passed'] and receipt['compiled_common_hdl']==170
    assert receipt['manifest_sha256']==MANIFEST and len(receipt['input_pins'])==72660
    assert not receipt['source_contract_passed'] and not receipt['full_wrapper_elaborated']
    assert all(Path(p).resolve(strict=True)==Path(q) for p,q in receipt['input_aliases'].items())
    merge(receipt['input_pins'])
    assert manifest['variant']==VARIANT and manifest['qualification']=='UNQUALIFIED'
    assert manifest['processor_platform_simulator_sha256']==MODEL and manifest['simulator_sha256'] is None
    for key in ('hardware_defines','core_mhz','write_slots','l2_sets','source_closure'):
        assert manifest[key]==old[key]
    assert len(manifest['hardware_defines'])==159
    assert manifest['hardware_defines']==(source/'defines.txt').read_text().splitlines()
    assert not any(manifest[k] for k in ('full_soc_lint','canonical_gate_passed','standard_suite','hardware_acceptance'))
    a,b=({r['frozen']:r for r in m['files']} for m in (old,manifest))
    assert set(a)==set(b) and len(b)==192
    assert sorted(n for n in a if a[n]['sha256']!=b[n]['sha256'])==export.CHANGES
    assert manifest['changed_parent_payloads']==export.CHANGES and manifest['changed_flow_payloads']==[]
    for name,row in b.items():
        p=source/name
        assert sha(p)==row['sha256'] and p.stat().st_size==row['bytes']
        assert row['parent_sha256']==a[name]['sha256'] and sha(prior/name)==a[name]['sha256']
        export.check_delta(name,(prior/name).read_bytes(),p.read_bytes())
        pins[str(p)]=row['sha256']
    core=ROOT/'qualified-pair-credit-core-r1'
    pc=ROOT/'qualified-pair-credit-soc-r1'
    prepared=load(pc/'prepared.json');closed=load(pc/'build-closed.json')
    assert closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged']
    assert closed['binary_sha256']==MODEL and closed['structural_debt_count']==98
    assert closed['structural_warnings_unchanged'] and not closed['errors']
    assert prepared['directed_model']==CORE_MODEL and len(prepared['intersecting_rtl_sources'])==102
    assert prepared['changes']==export.native.CHANGES and prepared['added_defines']==[]
    for name in prepared['intersecting_rtl_sources']:
        assert sha(pc/'source'/name)==sha(core/'candidate'/name)
    for binary,digest in ((core/'obj/tb_ventium',CORE_MODEL),
        (pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted',MODEL)):
        assert sha(binary)==digest;pins[str(binary)]=digest
    directed=load(ROOT/'qualified-pair-credit-core-audit-r1.json')
    assert directed['directed_passed'] and directed['counts']==dict(
        native_children=180,full_trace_pairs=90,candidate_records=47886,candidate_v_retirements=5349)
    merge(directed['pins'])
    boundary=load(ROOT/'qualified-pair-credit-boundaries-audit-r1.json')
    assert boundary['audit_passed'] and boundary['native_passes']==6
    assert boundary['original_cdc_still_failed'] and boundary['native_failure_count']==1
    merge(boundary['pins'])
    keyboard=load(ROOT/'qualified-pair-credit-input-r1/audit.json')
    assert keyboard['passed'] and keyboard['model']==MODEL and not keyboard['windows_ui']
    merge(keyboard['artifacts'])
    cmroot=pc/'coremark-ui-disabled-r1'
    cm=load(cmroot/'closed.json');cm_audit=load(cmroot/'audit.json')
    assert cm['passed'] and cm['pins_unchanged'] and cm['all_children_reaped']
    assert cm_audit['passed'] and cm_audit['model']==MODEL and cm_audit['no_oom']
    assert [r['ticks'] for r in cm['results']]==[4771298,4755366]
    assert all(r['parent_ticks']==r['candidate_ticks'] for r in cm_audit['measurements'])
    merge(cm_audit['artifact_pins'])
    gate_root=ROOT/'qualified-reference-profile-r1/gate-r1'
    gate=load(gate_root/'audit.json');gate_start=load(gate_root/'started.json')
    assert gate['audit_completed'] and not gate['gate_passed'] and gate['native_exit']==2
    assert (gate['functional_passes'],gate['functional_records'],gate['functional_v_retired'])==(108,80800,30132)
    assert gate['cycle_records_unchanged'] and gate['cycle_argv_checked']
    assert list(gate['cycle_bands'].values()).count('FAIL')==9
    merge(gate_start['pins']);merge(gate['artifacts'])
    sys.path.insert(0,str(REPO/'verif/qemu-trace'))
    import qualified_profile
    qualified_profile.select(Path(gate_start['environment']['VTM_QEMU_PROFILE_BUILD']))
    for p in (Path(__file__).resolve(),Path(export.__file__).resolve(),
              source/'defines.txt',source/'source-audit.json'):
        pins[str(p)]=sha(p)
    assert all(Path(p).is_file() and sha(p)==h for p,h in pins.items()),'source/evidence drift'
    return pins


if __name__=='__main__':
    pins=check()
    print(json.dumps(dict(pins_checked=len(pins),diagnostic_timing_only=True,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False)))
