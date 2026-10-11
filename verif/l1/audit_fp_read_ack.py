#!/usr/bin/env python3
"""Re-read read-ACK source closure and complete cold architectural/cycle evidence."""
import argparse
import io
import json
from pathlib import Path
import re
import subprocess
from audit_next_query_payload import sha, load, module, REPO, compare, tracefmt, check_faultlog
from prepare_fp_read_ack_split import PARENTS, transform
from run_fp_read_ack_fragments import expected_faults


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for flag in ('root','parent'): ap.add_argument('--'+flag,type=Path,required=True)
    args=ap.parse_args()
    root,parent=args.root.resolve(strict=True),args.parent.resolve(strict=True)
    core=root/'core-r1'
    assert __debug__ and root.is_relative_to(Path('/home/yukidama/external/tmp').resolve())
    built,started=load(core/'build-closed.json'),load(core/'build-started.json')
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    models=dict(control=parent/'obj/tb_ventium',candidate=core/'obj/tb_ventium')
    assert sha(models['control'])==started['parent_model']=='8c8898416ab8af4e6e53f9c4d94e3d9c2bbd1020edce3abdb300272dfc8104d6'
    assert sha(models['candidate'])==built['binary_sha256']=='b5554a977cd1ef4f12ee4a55a92fa514608cc902178aec2060a71fd00537e442'
    assert sorted(started['changes'])==sorted(PARENTS)
    observed=sorted(str(p.relative_to(core/'candidate')) for p in (core/'candidate').rglob('*')
        if p.is_file() and sha(p)!=sha(parent/'candidate'/p.relative_to(core/'candidate')))
    assert observed==sorted(PARENTS)
    for name in PARENTS:
        assert (core/'candidate'/name).read_text()==transform(name,(parent/'candidate'/name).read_text())
    pins=started['pins'].copy()
    owners=[]

    def owner(unit,invocation,code=0):
        actual=dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
            '-pSubState','-pMainPID','-pExecMainStatus','-pInvocationID'],text=True).splitlines())
        assert actual==dict(SubState='exited' if code==0 else 'failed',MainPID='0',
                            ExecMainStatus=str(code),InvocationID=invocation),(unit,actual)
        owners.append(dict(unit=unit,**actual))

    owner('ventium-fp-read-ack-core-oct11.service',started['invocation'])
    leaf=load(root/'leaf-r2/closed.json'); seam=load(root/'seam-r1/closed.json')
    assert leaf['passed'] and leaf['pins_unchanged'] and len(leaf['runs'])==13
    pins.update(load(root/'leaf-r2/pins.json')); pins.update(seam['pins'])
    assert seam['passed'] and seam['samples']==2048 and seam['comparisons']==12288
    for folder,rows,key in ((root/'leaf-r2',leaf['runs'],'label'),(root/'seam-r1',seam['runs'],'name')):
        for row in rows:
            name=row[key]
            expected=int(name.endswith('-negative') or name.startswith('drop_') or name=='wrong_backend')
            assert row['native_exit']==expected
            assert sha(folder/(name+'.log'))==row['log_sha256']
    profiles=[]
    for model in models.values():
        stamp=model.parent/'Vventium_top__verFiles.dat'
        cmd=next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
        profiles.append(set(re.findall(r'\+define\+(\w+)',cmd)))
        assert ' --assert ' in cmd and not {'SYNTHESIS','VTM_NO_DPI'} & profiles[-1]
        pins.update({str(p):sha(p) for p in (model,stamp)})
    assert profiles[0]==profiles[1] and len(profiles[0])==150
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH_RELOC','VEN_FP_LOAD_EARLY_CMD'} <= profiles[0]
    native=module('native',REPO/'verif/sys/run-native-system.py')
    helper=Path('/home/yukidama/external/tmp/ventium-fp-exec-cut.MNkzxfBO/system/run_same_profile_fp.py').resolve()
    fp=module('fp_grade',helper); pins[str(helper)]=sha(helper)
    counts=dict(cases=0,architectural_records=0,targeted_memory_v=0,agi_accepts=0)
    fragment_records=fragment_v=0
    for label,cases in (('memory',72),('fp',72),('agi',12),('fragments',48)):
        folder=root/(label+'-r1'); info,done=load(folder/'started.json'),load(folder/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert len(done['measurements'])==cases*4
        pins.update(info['pins'])
        owner('ventium-fp-read-ack-'+label+'-oct11.service',info['invocation'])
        leaves=sorted(folder.glob('*/closed.json')); assert len(leaves)==cases
        for receipt in leaves:
            path=receipt.parent; closed=load(receipt)
            assert closed['passed'] and sha(path/'fixture.bin')==closed['image_sha256']
            gold=tracefmt.read_trace(str(path/'golden.vtrace'))
            symbols={p[2]:int(p[0],16) for s in subprocess.check_output(['nm','-n',path/'fixture.elf'],text=True).splitlines()
                     if len(p:=s.split())==3 and p[0]!='U'}
            assert gold.sys and gold.x87==(label!='memory')
            limit=2500 if label=='fragments' else 2000
            for latency in (0,7):
                records={}; agi={}
                for name,model in models.items():
                    for mode in ('cycle-func','cycle'):
                        stem='%s-lat%d-%s' % (name,latency,mode)
                        command=load(path/(stem+'.command.json'))
                        assert str(model) in command and '--'+mode in command and '--l1-axi' in command
                        assert '--system' in command and '--cosim' in command
                        assert command[command.index('--max-insn')+1]==str(limit)
                        rc=load(path/(stem+'.exit.json'))['native_exit']; assert rc==133
                        stdout,stderr=(path/(stem+'.stdout')).read_text(),(path/(stem+'.stderr')).read_text()
                        expected=expected_faults(closed['measurements'][0]['case']) if label=='fragments' else {}
                        check_faultlog.check_counts(check_faultlog.read_counts(stdout.splitlines()),expected)
                        assert not native.FATAL.search(stdout+stderr)
                        tr=tracefmt.read_trace(str(path/(stem+'.vtrace')))
                        assert [r['n'] for r in tr.records]==list(range(len(gold.records)))
                        assert [r['pc'] for r in tr.records]==[r['pc'] for r in gold.records]
                        records[name,mode]=tr.records
                        if mode=='cycle-func':
                            (native.grade_native if label=='memory' else fp.grade_fp_native)(tr,stdout,stderr,rc,133,limit)
                            log=io.StringIO()
                            assert compare.compare_func(gold,tr,False,0xffffffff,False,20,log,sys_both=True)==0,log.getvalue()
                            if name=='candidate':
                                if label=='fragments': fragment_records+=len(tr.records)
                                else: counts['architectural_records']+=len(tr.records)
                        else: agi[name]=re.findall(r'^\[FETCHDBG:AGIPRIME\] .+$',stdout,re.M)
                for mode in ('cycle-func','cycle'): assert records['control',mode]==records['candidate',mode]
                if label=='memory': counts['targeted_memory_v']+=sum(int(r['pc'],0)==symbols['hot_load'] and r.get('pipe')=='V' and r.get('paired') for r in records['candidate','cycle'])
                if label=='agi':
                    assert agi['control']==agi['candidate'] and agi['candidate']
                    counts['agi_accepts']+=len(agi['candidate'])
                if label=='fragments': fragment_v+=sum(r.get('pipe')=='V' and r.get('paired') for r in records['candidate','cycle'])
            if label!='fragments': counts['cases']+=1
        pins.update({str(p):sha(p) for p in folder.rglob('*') if p.is_file()})
    assert counts==dict(cases=156,architectural_records=75192,targeted_memory_v=1500,agi_accepts=350)
    assert fragment_records==141510 and fragment_v==29640
    folder=root/'faults-r1'; info,done=load(folder/'started.json'),load(folder/'closed.json')
    assert done['passed'] and done['pins_unchanged'] and not done['errors'] and len(done['measurements'])==32
    pins.update(info['pins'])
    # The driver runs inside build_scope's transient scope. Its INVOCATION_ID
    # correctly names that scope, not the retained outer service. Prove both
    # owners and their link instead of treating the two IDs as interchangeable.
    fault_unit='ventium-fp-read-ack-faults-oct11.service'
    owner(fault_unit,'63394e00fcec45d2b28981ff3e6cf5aa')
    outer_pid=subprocess.check_output(['systemctl','--user','show',fault_unit,
        '--property=ExecMainPID','--value'],text=True).strip()
    journal=[json.loads(line) for line in subprocess.check_output(['journalctl','--user',
        '_SYSTEMD_INVOCATION_ID='+info['invocation'],'--no-pager','-o','json'],text=True).splitlines()]
    progress=[]
    for row in journal:
        msg=row.get('MESSAGE')
        if isinstance(msg,str) and msg.startswith('{"case":'):
            assert row['_SYSTEMD_INVOCATION_ID']==info['invocation']
            assert re.fullmatch(r'ventium-build-1000-'+outer_pid+r'-\d+\.scope',row['_SYSTEMD_USER_UNIT'])
            assert 'run_fp_read_ack_faults.py' in row['_CMDLINE']
            item=json.loads(msg)
            assert item['closed'] and item['errors']==0
            progress.append(item['case'])
    assert progress==info['cases']
    assert all(sha(folder/p)==h for p,h in done['artifacts'].items())
    fault_records=0
    for case in sorted(folder.glob('case-*')):
        records={}
        for name in models:
            for tag in ('gate','full-uv'):
                receipt=load(case/(name+'-'+tag+'.exit.json'))
                assert receipt['native_exit']==0 and not receipt['timed_out'] and receipt['affinity']==[12]
            gold=tracefmt.read_trace(str(case/name/'qemu.vtrace')); tr=tracefmt.read_trace(str(case/name/'cycle-func.vtrace'))
            log=io.StringIO()
            assert compare.compare_func(gold,tr,False,0xffffffff,False,20,log,sys_both=True)==0,log.getvalue()
            records[name]=tr.records
        assert records['control']==records['candidate']
        assert sha(case/'control/image/test.bin')==sha(case/'candidate/image/test.bin')
        fault_records+=len(records['candidate'])
    assert fault_records==23585
    pins.update({str(p):sha(p) for p in folder.rglob('*') if p.is_file()})
    verify=load(core/'verify-closed.json'); vst=load(core/'verify-started.json')
    assert verify['pins_unchanged'] and verify['canonical_gate_native_exit']==2 and not verify['canonical_gate_passed']
    assert not verify['masks_or_goldens_or_bands_changed']
    owner('ventium-fp-read-ack-verify-oct11.service',vst['invocation'],1); pins.update(vst['pins'])
    cycles=sorted((core/'generic-work').glob('*.cycle_rtl.vtrace')); assert len(cycles)==20
    for p in cycles:
        q=parent/'generic-work'/p.name
        assert tracefmt.read_trace(str(p)).records==tracefmt.read_trace(str(q)).records
        pins.update({str(f):sha(f) for f in (p,q)})
    for p in (Path(__file__),Path(__file__).with_name('audit_next_query_payload.py'),
              core/'build-closed.json',core/'build-started.json',core/'verify-closed.json',core/'verify-started.json',
              root/'canonical-inventory.json',root/'leaf-r2/closed.json',root/'seam-r1/closed.json'):
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(audit_complete=True,model_sha256=built['binary_sha256'],pins=pins,retained_owners=owners,
        counts=counts,fragment_cases=48,fragment_records=fragment_records,fragment_paired_v=fragment_v,
        fault_cases=16,fault_records=fault_records,all_20_canonical_cycle_streams_identical=True,
        canonical_gate_passed=False,gameplay_ipc=None,standard_suite=False,physical_board=False,reset_sweep=False)
    with (root/'audit.json').open('x') as stream: json.dump(result,stream,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','retained_owners')},indent=2))


if __name__=='__main__': main()
