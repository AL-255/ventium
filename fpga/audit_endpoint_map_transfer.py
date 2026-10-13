"""Audit the closed full-PC transfer/freeze/lint/short seeds; not acceptance."""
import argparse
import json
from pathlib import Path
import subprocess

import build_endpoint_map_soc as native
import prepare_endpoint_map_synthesis as timing


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root',type=Path,required=True)
    root=ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root==timing.ROOT
    sha,load=native.sha,native.load
    pc,source=root/'endpoint-map-soc-r1',root/'endpoint-map-fpga-r1'
    pins=native.admit(root/'endpoint-map-core-r1',root/'endpoint-map-audit-r1.json')
    before,closed=load(pc/'build-started.json'),load(pc/'build-closed.json')
    assert closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged']
    assert closed['binary_sha256']==sha(pc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==timing.MODEL
    assert before['changes']==native.CHANGES and not before['added_defines']
    assert len(before['intersecting_rtl_sources'])==102 and not before['canonical_gate_passed']
    assert closed['structural_warnings_unchanged'] and closed['structural_debt_count']==98
    pins.update(before['pins'])
    manifest,freeze=load(source/'input-manifest.json'),load(source/'freeze-receipt.json')
    assert sha(source/'input-manifest.json')==freeze['manifest_sha256']==timing.MANIFEST
    assert freeze['source_contract_passed'] and manifest['qualification']=='UNQUALIFIED'
    assert manifest['simulator_sha256']==timing.MODEL and manifest['variant']=='endpoint_map_timing'
    assert manifest['changed_parent_payloads']==list(timing.CHANGES)
    assert len(manifest['files'])==190 and len(manifest['hardware_defines'])==158
    assert manifest['core_mhz']==40 and manifest['write_slots']==16 and manifest['l2_sets']==1024
    assert not any(manifest[k] for k in ('canonical_gate_passed','standard_suite','hardware_acceptance'))
    pins.update(freeze['input_pins'])
    pins.update({str(source/r['frozen']):r['sha256'] for r in manifest['files']})
    for name in before['intersecting_rtl_sources']:
        assert sha(pc/'source'/name)==sha(root/'endpoint-map-core-r1/candidate'/name)
    lint=load(root/'endpoint-map-lint-r1/closed.json')
    assert lint['passed'] and lint['native_exit']==0 and lint['inputs_unchanged']
    assert lint['source_manifest_sha256']==timing.MANIFEST and lint['hardware_defines']==158
    assert not lint['full_soc_lint'] and not lint['fpga_qualified']
    pins.update(load(root/'endpoint-map-lint-r1/started.json')['pins'])
    cm,audit=load(pc/'coremark/closed.json'),load(pc/'coremark/audit.json')
    assert cm['passed'] and cm['pins_unchanged'] and cm['all_children_reaped']
    assert audit['passed'] and audit['model']==timing.MODEL and audit['no_oom']
    assert not any(audit[k] for k in ('duration_valid','standard_suite','physical_board'))
    assert audit['gameplay_ipc'] is None
    parent=load(root/'prime-reg-soc-r1/coremark/closed.json')
    assert parent['passed']
    assert [r['ticks'] for r in cm['results']]==[r['ticks'] for r in parent['results']]==[4767218,4753406]
    pins.update(load(pc/'coremark/started.json')['pins']); pins.update(audit['artifact_pins'])
    prepared=load(root/'endpoint-map-timing-prepared.json')
    assert prepared['unchanged_guard_lifecycle'] and prepared['controllers_generated_not_launched']
    assert prepared['source_manifest_sha256']==timing.MANIFEST and prepared['model_sha256']==timing.MODEL
    pins.update(prepared['template_pins']); pins.update(prepared['outputs'])
    owners={}
    for unit,inv in (
        ('ventium-endpoint-map-soc-oct13-r1.service',before['invocation']),
        ('ventium-endpoint-map-lint-oct13-r1.service',load(root/'endpoint-map-lint-r1/started.json')['invocation']),
        ('ventium-v-carry-cm10-endpoint-map-oct13-r1.service',load(pc/'coremark/started.json')['invocation'])):
        owner=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
            '-pMainPID','-pSubState','-pExecMainStatus','-pInvocationID','-pResult'],text=True).splitlines())
        assert owner==dict(MainPID='0',SubState='exited',ExecMainStatus='0',InvocationID=inv,Result='success')
        owners[unit]=owner
    for p in (Path(__file__),pc/'build-started.json',pc/'build-closed.json',pc/'build.log',
              pc/'coremark/audit.json',source/'input-manifest.json',source/'freeze-receipt.json',
              source/'source-contract.log',root/'endpoint-map-lint-r1/closed.json',
              root/'endpoint-map-lint-r1/native.log',root/'endpoint-map-timing-prepared.json',
              root/'prime-reg-soc-r1/coremark/closed.json'):
        pins[str(p)]=sha(p)
    assert native.stable(pins)
    result=dict(passed=True,pins=pins,owners=owners,model=timing.MODEL,manifest=timing.MANIFEST,
        shared_core_sources=102,changes=native.CHANGES,short_coremark_ticks=[r['ticks'] for r in cm['results']],
        cpu_hierarchy_lint=True,full_soc_lint=False,platform_structural_debt=98,
        canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
        duration_valid=False,gameplay_ipc=None,fmax_mhz=None)
    native.save(root/'endpoint-map-transfer-audit-r1.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'},indent=2))


if __name__=='__main__':main()
