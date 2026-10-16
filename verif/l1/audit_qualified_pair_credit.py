"""Reconstruct and audit selected closed fault and full-wrapper native tests.

The first fault controller remains FAIL: its quad test printed a late fatal.
Only its twelve clean, unchanged non-quad rows are reused. Six separately
closed quad rows qualify the repaired fixture. Never rewrite the failed run
or describe this collected evidence as a successful original controller.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

import prepare_qualified_pair_credit as recipe
import run_qualified_pair_credit_faults as faults
import run_qualified_pair_credit_wrapper as wrapper
from run_parallel_tag_cache import sha


def owner(path, unit, expected_result, expected_invocation):
    started=json.loads((path/'started.json').read_text())
    props=dict(line.split('=',1) for line in subprocess.check_output(
        ['systemctl','--user','show',unit,'-p','MainPID','-p','SubState',
         '-p','Result','-p','InvocationID','-p','ExecMainStatus','-p','ExecStart',
         '-p','ExecMainStartTimestampMonotonic','-p','ExecMainExitTimestampMonotonic'],text=True).splitlines())
    assert props['MainPID']=='0' and props['SubState'] in ('exited','failed'),props
    assert props['InvocationID']==expected_invocation
    assert Path(re.search(r'--out ([^ ;]+)',props['ExecStart'])[1]).resolve()==path
    assert props['Result']==expected_result
    assert props['ExecMainStatus']==('0' if expected_result=='success' else '1')
    # INVOCATION_ID inside the build guard belongs to its child scope, not
    # the retained outer service. Verify both identities and their lifetime.
    events=[json.loads(line) for line in subprocess.check_output(['journalctl','--user',
        '_SYSTEMD_INVOCATION_ID='+started['invocation'],'-o','json','--no-pager'],text=True).splitlines()]
    assert events
    summaries=[]
    for event in events:
        assert event['_SYSTEMD_USER_UNIT']=='ventium-ipc-parallel32.scope'
        assert Path(re.search(r'--out ([^ ;]+)',event['_CMDLINE'])[1]).resolve()==path
        assert int(props['ExecMainStartTimestampMonotonic'])<=int(event['__MONOTONIC_TIMESTAMP'])<=int(props['ExecMainExitTimestampMonotonic'])
        if event['MESSAGE'].startswith('{'):
            summary=json.loads(event['MESSAGE'])
            if 'pins_unchanged' in summary:summaries.append(summary)
    assert len(summaries)==1 and summaries[0]['passed']==(expected_result=='success')
    assert summaries[0]['seconds']==json.loads((path/'closed.json').read_text())['seconds']
    return dict(service=props,scope_invocation=started['invocation'],scope_events=events)


def artifacts(row):
    assert row['build_exit']==row['native_exit']==0
    for path,value in row['artifacts'].items():assert sha(path)==value,path
    log=next(Path(path).read_text() for path in row['artifacts'] if path.endswith('/run.log'))
    assert log==row['log'] and not re.search(r'\bFAIL\b|%Fatal|%Error',log)
    binary=next(Path(path).resolve() for path in row['artifacts'] if path.endswith('/obj/test'))
    for process in Path('/proc').iterdir():
        if not process.name.isdigit():continue
        try: live=(process/'exe').resolve(strict=True)
        except (FileNotFoundError,PermissionError,ProcessLookupError):continue
        assert live!=binary,process
    archive=row['compiler_archive']
    assert sha(archive['path'])==archive['sha256']
    return {**row['artifacts'],archive['path']:archive['sha256']}


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for key in ('parent','faults','quad','wrapper','out'):
        ap.add_argument('--'+key,type=Path,required=True)
    args=ap.parse_args()
    parent,first,quad,seam=(getattr(args,key).resolve(strict=True) for key in
                             ('parent','faults','quad','wrapper'))
    source={name:(parent/'ventium/rtl/mem'/name).read_text() for name in recipe.PINS}
    changed=recipe.transform(source)
    manifest=json.loads((parent/'input-manifest.json').read_text())
    definitions=['+define+'+flag for flag in manifest['hardware_defines'] if flag!='SYNTHESIS']
    old=json.loads((first/'closed.json').read_text())
    repaired=json.loads((quad/'closed.json').read_text())
    integrated=json.loads((seam/'closed.json').read_text())
    assert not old['passed'] and len(old['rows'])==13
    assert '%Fatal' in old['rows'][-1]['log'] and old['rows'][-1]['label']=='quad'
    assert repaired['passed'] and repaired['pins_unchanged'] and len(repaired['rows'])==6
    assert integrated['passed'] and integrated['pins_unchanged'] and len(integrated['rows'])==2
    owners={
        'failed_original':owner(first,'ventium-qualified-pair-faults-oct16-r2.service','exit-code','1d0a002277024fd2af9a69f3f77e709d'),
        'repaired_quad':owner(quad,'ventium-qualified-pair-quad-oct16-r3.service','success','2ce7d4a82eda48f3bc45496422de8821'),
        'wrapper':owner(seam,'ventium-qualified-pair-wrapper-oct16-r3.service','success','0c43425c096f45cfabfa17809d89da57'),
    }
    pins={}
    # These successful receipts must still be entirely unchanged. The failed
    # controller's overbroad run-level pins include its obsolete quad fixture;
    # reconstruct each selected native input instead of waiving that drift.
    for receipt in (repaired,integrated):
        for path,value in receipt['pins'].items():assert sha(path)==value,path
        pins.update(receipt['pins'])
    rows=old['rows'][:12]+repaired['rows']
    assert len(rows)==18
    for label,top,extra,marker in faults.CASES:
        selected=[row for row in rows if row['label']==label]
        assert len(selected)==2 and {row['candidate'] for row in selected}=={False,True}
        for row in selected:
            command=row['command'];candidate=row['candidate']
            qualified=candidate and label!='quad_split'
            fixture=Path(command[-1]);master=Path(command[-2])
            assert fixture.read_text()==faults.fixture((faults.HERE/(top+'.sv')).read_text(),qualified)
            assert master.read_text()==(changed if candidate else source)['ven_axi_master.sv']
            assert [arg for arg in command if arg.startswith('+define+')]==definitions+['+define+'+flag for flag in extra]
            assert '--assert' in command and all('-Werror-'+name in command for name in
                ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT'))
            assert marker in row['log']
            pins.update(artifacts(row));pins[str(master)]=sha(master)
    assert (seam/'tb_qualified_pair_wrapper.sv').read_text()==wrapper.fixture()
    assert (seam/'qualified_pair_credit_wrapper.svh').read_text()==(faults.HERE/'qualified_pair_credit_wrapper.svh').read_text()
    for name in ('ven_axi_master.sv','ventium_l1_axi.sv'):
        assert (seam/name).read_text()==changed[name]
    for row in integrated['rows']:
        assert row['coverage']=='PAIR-CREDIT-WRAPPER-OK U=65 V=2 quad=1 blocked=30 full=53 reset=1 deny=4 AW=100'
        pins.update(artifacts(row))
    for path in (Path(__file__).resolve(),first/'closed.json',quad/'closed.json',seam/'closed.json',
                 *(faults.HERE/(top+'.sv') for _,top,_,_ in faults.CASES)):
        pins[str(path)]=sha(path)
    result=dict(passed=True,scope='selected native matrix, not original controller or processor acceptance',
        original_controller_still_failed=True,fault_native_passes=18,wrapper_native_passes=2,
        retained_owners=owners,pins=pins,whole_core=False,standard_suite=False,hardware_acceptance=False,
        gameplay_ipc=None,fmax_mhz=None)
    out=args.out.resolve()
    assert out.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    with out.open('x') as f:json.dump(result,f,indent=2)
    print('PAIR-CREDIT-AUDIT-OK native=18 wrapper=2 pins='+str(len(pins)))


if __name__=='__main__':main()
