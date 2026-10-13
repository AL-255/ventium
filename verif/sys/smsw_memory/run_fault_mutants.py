"""Require fault witnesses to reject absent faults and dirty destination bytes.

Mutation changes only microtest instruction bytes, never RTL, Doom or saved
machine state. Dirty-byte variants alter fixture initialization to prove both
sides of the no-partial-write checks are live. They are not real fault runs.
"""
import argparse
import concurrent.futures
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

from run_probe import HERE, EXTERNAL, sha


def save(path,value):
    with path.open('x') as stream:
        json.dump(value,stream,indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for key in ('fault','audit','model','out'):
        ap.add_argument('--'+key,required=True,type=Path)
    args = ap.parse_args()
    root,fault,model = args.out.resolve(),args.fault.resolve(strict=True),args.model.resolve(strict=True)
    assert __debug__ and root.is_relative_to(EXTERNAL) and root!=EXTERNAL and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==EXTERNAL and shutil.disk_usage(EXTERNAL).free>4*1024**3
    audited = json.loads(args.audit.read_text())
    assert audited['audit_passed'] and audited['differential_cases']==85 and audited['intel_spec_only_cases']==20
    assert all(sha(p)==h for p,h in audited['pins'].items())
    done = json.loads((fault/'closed.json').read_text())
    assert len(done['rows'])==45 and not done['passed']
    assert sha(model)=='cbf749f16babd88fb5dcf508c2381d48b77dedd348e9b23a5ed9083de9f4e65e'
    cpus=sorted(os.sched_getaffinity(0))
    assert len(cpus)==8
    pins = dict(audited['pins'])
    pins.update({str(p):sha(p) for p in (Path(__file__),HERE/'run_probe.py',args.audit,model)})
    root.mkdir()
    shutil.copyfile(Path(__file__),root/Path(__file__).name)
    jobs=[]
    for row in done['rows']:
        name,c=row['name'],row['case']
        original=fault/name/'probe.bin'
        data=original.read_bytes()
        symbols={s.split()[2]:int(s.split()[0],16) for s in subprocess.check_output(
            ['nm','-n',fault/name/'probe.elf'],text=True).splitlines() if len(s.split())==3}
        pc,after=[symbols[k]-0xf0000 for k in ('smsw_probe','smsw_after')]
        assert 0<=pc<after<65536
        mutations=[('no-op',data[:pc]+bytes([0x90])*(after-pc)+data[after:])]
        if c['CASE']<8:
            for label,addr,byte in (('dirty-first',0x180ffd if c['CASE']>=4 else 0x400ffd,2),
                                    ('dirty-second',0x1a0000 if c['CASE']>=4 else 0x401000,0)):
                needle=bytes.fromhex('c705')+addr.to_bytes(4,'little')+bytes([0xa5])*4
                assert data.count(needle)==1,(name,label)
                offset=data.index(needle)+6+byte
                altered=bytearray(data)
                altered[offset]=0xa4
                mutations.append((label,bytes(altered)))
        for label,altered in mutations:
            path=root/(name+'-'+label+'.bin')
            path.write_bytes(altered)
            jobs.append(dict(name=path.stem,image=str(path),sha256=sha(path),mutation=label,case=c,
                             pc=pc+0xf0000,expected_faults=0 if label=='no-op' else 1))
    assert len(jobs)==125
    save(root/'started.json',dict(pins=pins,jobs=jobs,invocation=os.environ.get('INVOCATION_ID'),affinity=cpus))
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VENTIUM_','TB_','AXI_','QEMU_'))}
    env.update(AXI_RLAT='7',AXI_WLAT='7')
    def run(index,job):
        pair=cpus[2*(index%4):2*(index%4)+2]
        name=job['name']
        command=['taskset','-c',','.join(map(str,pair)),'timeout','--kill-after=2s','15s',str(model),
            '--system','--cosim','--cycle-func','--l1-axi','--image',job['image'],'--out',str(root/(name+'.vtrace')),
            '--max-insn','3000','--max-cycles','1000000','--quiesce','4096','+ven_faultlog','+ven_seglog']
        save(root/(name+'-command.json'),command)
        seen={}
        with (root/(name+'.log')).open('x') as log:
            child=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT)
            try:
                while child.poll() is None:
                    queue=[child.pid]
                    while queue:
                        pid=queue.pop()
                        try:
                            proc=Path('/proc')/str(pid)
                            queue.extend(map(int,(proc/'task'/str(pid)/'children').read_text().split()))
                            if (proc/'exe').readlink().resolve()==model:
                                seen[pid]=sorted(os.sched_getaffinity(pid))
                                assert seen[pid]==pair
                        except (FileNotFoundError,ProcessLookupError):
                            pass
                    time.sleep(.002)
                code=child.wait()
            finally:
                if child.poll() is None:
                    child.terminate()
                    child.wait(timeout=5)
        text=(root/(name+'.log')).read_text()
        faults=[s for s in text.splitlines() if s.startswith('[FAULT] vec=')]
        assert code==135 and seen and 'isa-debug-exit' in text,(name,code)
        assert len(faults)==job['expected_faults'],(name,faults)
        if faults:
            n=job['case']['CASE']
            vector=6 if n==0 else 13 if n<4 else 14
            assert faults[0].startswith(f'[FAULT] vec={vector} ')
            assert re.search(r' pc=([0-9a-f]+) ',faults[0])[1]==f'{job["pc"]:08x}'
        row=dict(name=name,rejected=True,native_exit=code,observed_affinity=seen,faults=faults)
        save(root/(name+'-closed.json'),row)
        return row
    begin=time.monotonic()
    result=dict(passed=False,rows=[],errors=[],standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures={pool.submit(run,i,j):j['name'] for i,j in enumerate(jobs)}
        for future in concurrent.futures.as_completed(futures):
            try:
                result['rows'].append(future.result())
            except Exception as error:
                result['errors'].append(dict(case=futures[future],error=repr(error)))
    result.update(seconds=time.monotonic()-begin,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                  images_unchanged=all(sha(j['image'])==j['sha256'] for j in jobs))
    result['passed']=len(result['rows'])==125 and not result['errors'] and result['pins_unchanged'] and result['images_unchanged']
    result['artifacts']={str(p):sha(p) for p in root.iterdir() if p.is_file()}
    save(root/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','artifacts')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
