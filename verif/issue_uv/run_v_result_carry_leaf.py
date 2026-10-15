"""Execute actual decoder/issuer/V ALU with exact-parent and negative controls.

No full-core, standard-suite or FPGA acceptance is implied. Source files and
defines come from the closed current directed model, not the dirty checkout.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import time
import traceback

import prepare_v_result_carry as recipe

REPO=Path(__file__).resolve().parents[2]
MODEL='c9e4b9f86ad080f72ffd8ecef3d4ffc73eb1ecb8574ba7cd185bcae4fa3a643a'
FILES=('rtl/ventium_pkg.sv','rtl/core/ventium_alu_pkg.sv','rtl/core/ventium_decode_pkg.sv',
       'rtl/core/decode.sv','rtl/core/issue_uv.sv','rtl/core/v_pipe.sv')
COUNTS=dict(decode=6529029,alu=9362160,incdec_cf_one=312072,bytes=7864320,words=748920,dwords=748920)


def class_mask(definitions):
    return [True,*[name in definitions for name in ('VEN_P54_DUAL_LOAD_PAIR',
        'VEN_P54_REGMEM_PRIME','VEN_P54_DUAL_STORE_PAIR','VEN_P54_LOAD_STORE_PAIR')]]


def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def check_receipt(root):
    start,done=[json.loads((root/n).read_text()) for n in ('started.json','closed.json')]
    assert done['passed'] and done['pins_unchanged'] and not done['errors']
    assert not done['whole_core'] and all(done['memory_events'][k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    assert [(r['profile'],r['mutant']) for r in done['rows']]==[(p,m) for p in ('current','baseline') for m in range(3)]
    assert len(done['builds'])==2
    for row in done['builds']:
        assert row['native_exit']==0 and row['actual_wait'] and row['affinity']==list(range(32))
    for row in done['rows']:
        assert row['actual_wait'] and row['affinity']==[13]
        log=(root/row['log']).read_text()
        if row['mutant']==0:
            assert row['native_exit']==0 and 'V-RESULT-CARRY-OK ' in log
            assert all(row['counts'][k]==v for k,v in COUNTS.items())
            assert row['counts']['rejected_cf']>0 and row['counts']['accepted_v']>0
            mask=class_mask(start['definitions'] if row['profile']=='current' else [])
            assert [(n>0) for n in row['classes']]==mask
        else:
            marker='V-CARRY-DATAPATH' if row['mutant']==1 else 'V-CARRY-ELIGIBILITY'
            assert row['native_exit']!=0 and marker in log and 'V-RESULT-CARRY-OK ' not in log
    pins=start['pins']|done['artifacts']
    assert all(sha(p)==h for p,h in pins.items())
    return pins|{str(root/n):sha(root/n) for n in ('started.json','closed.json')}


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','out'):ap.add_argument('--'+name,type=Path,required=True)
    args=ap.parse_args();parent=args.parent.resolve(strict=True);out=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch and scratch.stat().st_dev!=REPO.stat().st_dev
    assert out!=scratch and out.is_relative_to(scratch) and not out.exists()
    assert not out.is_relative_to(parent) and not parent.is_relative_to(out)
    assert shutil.disk_usage(scratch).free>5*1024**3 and os.sched_getaffinity(0)==set(range(32))
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT']=='ventium-ipc-parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE']=='ipc_parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN']=='/tools/verilator/v5.046/bin/verilator'
    assert os.environ['INVOCATION_ID']
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=4G','MemorySwapMax=0'],check=True)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    old,built=[json.loads((parent/n).read_text()) for n in ('build-started.json','build-closed.json')]
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(parent/'obj/tb_ventium')==built['binary_sha256']==MODEL
    source=parent/'candidate';definitions=old['definitions']
    assert len(definitions)==len(set(definitions))==153
    assert {'VEN_P54_DUAL_LOAD_PAIR','VEN_P54_DUAL_STORE_PAIR',
            'VEN_P54_LOAD_STORE_PAIR','VEN_X87_MF_STRICT'}<=set(definitions)
    assert 'VEN_P54_REGMEM_PRIME' not in definitions # preserve the actual disabled path
    pins={}
    for name in set(FILES)|set(recipe.HASHES):
        p=source/name;assert sha(p)==old['pins'][str(p)];pins[str(p)]=sha(p)
    out.mkdir();paths=[]
    for name in FILES:
        target=out/Path(name).name;data=(source/name).read_text()
        if name in recipe.HASHES:data=recipe.transform(data,name)
        target.write_text(data);paths.append(target)
    for name in recipe.HASHES:
        if name not in FILES:(out/Path(name).name).write_text(recipe.transform((source/name).read_text(),name))
    v_parent=(source/'rtl/core/v_pipe.sv').read_text()
    assert v_parent.count('module v_pipe\n')==v_parent.count('endmodule : v_pipe')==1
    v_parent=v_parent.replace('module v_pipe\n','module v_pipe_parent\n').replace('endmodule : v_pipe','endmodule : v_pipe_parent')
    (out/'v_pipe_parent.sv').write_text(v_parent);paths.append(out/'v_pipe_parent.sv')
    template=Path(__file__).with_name('tb_v_result_carry.sv');shutil.copyfile(template,out/template.name);paths.append(out/template.name)
    for p in (Path(__file__),Path(recipe.__file__),template,REPO/'tools/build_scope.sh',REPO/'tools/verilator_serial.sh',
              Path(os.environ['VENTIUM_VERILATOR_BIN']),parent/'build-started.json',parent/'build-closed.json',
              parent/'obj/tb_ventium',*out.iterdir()):pins[str(p.resolve())]=sha(p)
    group=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().strip().split('::',1)[1].lstrip('/')
    def save(name,value):
        with (out/name).open('x') as f:json.dump(value,f,indent=2)
    def run(label,command,affinity,timeout):
        command=['taskset','-c',','.join(map(str,sorted(affinity))),*map(str,command)]
        with (out/(label+'.log')).open('x') as f:
            child=subprocess.Popen(command,stdout=f,stderr=subprocess.STDOUT,start_new_session=True,pass_fds=(9,))
            try:
                os.sched_setaffinity(child.pid,affinity);actual=sorted(os.sched_getaffinity(child.pid))
                assert actual==sorted(affinity)
                remaining=550-(time.monotonic()-begin)
                if remaining<=0:raise TimeoutError('total native gate budget exhausted')
                code=child.wait(timeout=min(timeout,remaining))
            except BaseException:
                if child.poll() is None:os.killpg(child.pid,signal.SIGKILL)
                child.wait();raise
        return dict(command=command,native_exit=code,actual_wait=True,pid=child.pid,
                    affinity=actual,log=label+'.log',log_sha256=sha(out/(label+'.log')))
    save('started.json',dict(pins=pins,definitions=definitions,parent=str(parent),
        invocation=os.environ['INVOCATION_ID'],affinity=sorted(os.sched_getaffinity(0)),cgroup=str(group)))
    result=dict(passed=False,errors=[],rows=[],builds=[],whole_core=False,gameplay_ipc=None,
                standard_suite=False,hardware_acceptance=False)
    begin=time.monotonic()
    try:
        for profile in ('current','baseline'):
            defs=list(dict.fromkeys((definitions if profile=='current' else [])+['VTM_NO_DPI']))
            command=[REPO/'tools/verilator_serial.sh','--binary','--timing','--assert','-j','32',
                '-Wno-fatal','-Wno-UNUSED',*['-Werror-'+w for w in
                ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '--top-module','tb_v_result_carry','--Mdir',out/profile,*['+define+'+d for d in defs],*paths]
            build=run(profile+'-build',command,set(range(32)),180);result['builds'].append(build)
            assert build['native_exit']==0
            binary=out/profile/'Vtb_v_result_carry'
            for mutant in range(3):
                row=run(profile+'-'+str(mutant),[binary,'+mutant='+str(mutant)],{13},120)
                row.update(profile=profile,mutant=mutant,binary_sha256=sha(binary));result['rows'].append(row)
                text=(out/row['log']).read_text()
                if mutant:
                    marker='V-CARRY-DATAPATH' if mutant==1 else 'V-CARRY-ELIGIBILITY'
                    assert row['native_exit']!=0 and marker in text
                else:
                    m=re.search(r'^V-RESULT-CARRY-OK (.+)$',text,re.M)
                    assert row['native_exit']==0 and m
                    row['counts']={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',m[1]) if k!='classes'}
                    row['classes']=list(map(int,re.search(r'classes=([\d,]+)',m[1])[1].split(',')))
                    assert all(row['counts'][k]==v for k,v in COUNTS.items())
                    assert row['counts']['rejected_cf']>0 and row['counts']['accepted_v']>0
                    assert [(n>0) for n in row['classes']]==class_mask(defs)
        result['passed']=True
    except Exception as error:
        result['errors'].append(dict(error=repr(error),traceback=traceback.format_exc()))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
        memory_events=dict(line.split() for line in (group/'memory.events').read_text().splitlines()),
        artifacts={str(p):sha(p) for p in out.iterdir() if p.is_file()})
    for profile in ('current','baseline'):
        binary=out/profile/'Vtb_v_result_carry'
        if binary.exists():result['artifacts'][str(binary)]=sha(binary)
    result['passed'] &= result['pins_unchanged'] and all(result['memory_events'][k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    save('closed.json',result)
    if result['passed']:check_receipt(out)
    print(json.dumps({k:v for k,v in result.items() if k not in ('artifacts','rows','builds')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
