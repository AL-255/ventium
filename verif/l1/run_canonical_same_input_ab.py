#!/usr/bin/env python3
"""Replay both models on identical canonical input bytes and initial ESP.

QEMU chooses its loader stack based partly on invocation/environment length.
Historical runs can therefore have different initial ESP. Never normalize that
field away: run both models on one retained golden's exact input instead.
The candidate must also reproduce its own original complete trace verbatim.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time
from audit_timing_canonical_ab import REPO, require_identical, sha, tracefmt


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','candidate','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    parent,candidate=args.parent.resolve(strict=True),args.candidate.resolve(strict=True)
    out=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert shutil.disk_usage(scratch).free>4*1024**3
    work=candidate/'generic-work'
    recorded=json.loads((candidate/'verify-started.json').read_text())
    done=json.loads((candidate/'verify-closed.json').read_text())
    assert done['pins_unchanged'] and done['canonical_gate_native_exit'] in (0,2)
    assert not done['masks_or_goldens_or_bands_changed']
    envspec=recorded['environment']
    flags=shlex.split(envspec['TB_EXTRA_FLAGS'])
    assert flags==['--cycle-func','--l1-axi']
    assert envspec['AXI_RLAT']==envspec['AXI_WLAT']=='7'
    cache=Path(envspec['VERIFY_CACHE_DIR'])
    assert cache.resolve()==(candidate/'generic-cache').resolve()
    pins={}
    profiles=[]
    models={'control':parent/'obj/tb_ventium','candidate':candidate/'obj/tb_ventium'}
    for label,model in models.items():
        root=parent if label=='control' else candidate
        receipt=json.loads((root/'build-closed.json').read_text())
        assert receipt['passed'] and sha(model)==receipt['binary_sha256']
        stamp=model.parent/'Vventium_top__verFiles.dat'
        command=next(s for s in stamp.read_text().splitlines() if s.startswith('C '))
        defs=set(re.findall(r'\+define\+(\w+)',command))
        assert ' --assert ' in command and {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH_RELOC'}<=defs
        assert not {'SYNTHESIS','VTM_NO_DPI','VEN_SYS_FASTPATH_ALL'}&defs
        profiles.append(defs)
        for p in (model,stamp,root/'build-closed.json'):
            pins[str(p)]=sha(p)
    assert profiles[0]==profiles[1] and len(profiles[0])==150
    jobs=[s.split('\t') for s in (work/'jobs.txt').read_text().splitlines() if s.startswith('func\t')]
    assert len(jobs)==108 and len({s[1] for s in jobs})==108
    cases=[]
    for mode,name,source,load,entry,maxinsn,x87,portidx,fcpi,kind in jobs:
        assert mode=='func' and x87 in ('0','1') and int(maxinsn)>0
        src=Path(source)
        image,elf,original=[work/(name+'.func'+suffix) for suffix in ('.flat','.elf','_rtl.vtrace')]
        src_sha=hashlib.sha1(src.read_bytes()).hexdigest()
        elf_sha=hashlib.sha1(elf.read_bytes()).hexdigest()
        goldens=list(cache.glob(src_sha+'.'+elf_sha[:12]+'.*.func.x87'+x87+'.max'+maxinsn+'.vtrace'))
        assert len(goldens)==1,(name,goldens)
        golden=goldens[0]
        with golden.open() as stream:
            json.loads(stream.readline())
            esp=json.loads(stream.readline())['esp']
        assert 0<=int(esp,0)<2**32
        for p in (src,image,elf,original,golden):
            pins[str(p)]=sha(p)
        cases.append(dict(name=name,image=str(image),load=load,entry=entry,maxinsn=maxinsn,
            x87=x87=='1',esp=esp,original=str(original),golden=str(golden)))
    for p in (Path(__file__),REPO/'verif/l1/audit_timing_canonical_ab.py',work/'jobs.txt',
              candidate/'verify-started.json',candidate/'verify-closed.json',REPO/'verif/lib/verify_worker.sh'):
        pins[str(p)]=sha(p)
    out.mkdir()
    def save(path,value):
        with path.open('x') as stream:
            json.dump(value,stream,indent=2)
    save(out/'started.json',dict(pins=pins,cases=cases,invocation=os.environ.get('INVOCATION_ID'),
        affinity=sorted(os.sched_getaffinity(0)),models={k:str(v) for k,v in models.items()}))
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_'))}
    env.update(AXI_RLAT='7',AXI_WLAT='7',TMPDIR=str(out),PYTHONDONTWRITEBYTECODE='1')
    def run(case):
        folder=out/case['name']
        folder.mkdir()
        traces={}
        for label,model in models.items():
            path=folder/(label+'.vtrace')
            command=[str(model),'--image',case['image'],'--load',case['load'],'--entry',case['entry'],
                '--init-esp',case['esp'],'--out',str(path),'--max-insn',case['maxinsn'],
                *(['--x87'] if case['x87'] else []),*flags]
            save(folder/(label+'-command.json'),command)
            with (folder/(label+'.log')).open('x') as log:
                native=subprocess.run(['timeout','--kill-after=3s','60s',*command],env=env,
                    stdout=log,stderr=subprocess.STDOUT,timeout=70)
            save(folder/(label+'-exit.json'),dict(native_exit=native.returncode))
            assert native.returncode==0,(case['name'],label,native.returncode)
            text=(folder/(label+'.log')).read_text()
            assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED',text)
            traces[label]=tracefmt.read_trace(str(path))
        require_identical(traces['control'],traces['candidate'])
        require_identical(tracefmt.read_trace(case['original']),traces['candidate'])
        row=dict(case=case['name'],passed=True,records=len(traces['candidate'].records))
        save(folder/'closed.json',row)
        return row
    result=dict(same_input_regression_passed=False,rows=[],errors=[],
        canonical_gate_passed=done['canonical_gate_passed'],gameplay_ipc=None,standard_suite=False)
    begin=time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futures={pool.submit(run,case):case['name'] for case in cases}
        for future in concurrent.futures.as_completed(futures):
            try:
                result['rows'].append(future.result())
            except Exception as error:
                result['errors'].append(dict(case=futures[future],error=repr(error)))
    result['pins_unchanged']=all(sha(Path(p))==h for p,h in pins.items())
    result.update(seconds=time.monotonic()-begin,records=sum(r['records'] for r in result['rows']))
    result['same_input_regression_passed']=len(result['rows'])==108 and not result['errors'] and result['pins_unchanged']
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    return 0 if result['same_input_regression_passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
