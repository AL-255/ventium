#!/usr/bin/env python3
"""Compare cold flat/relocated system-dispatch fixtures on matched prebuilt models.

Complete QEMU architectural comparisons, actual U/V pairs, actual dispatch
witnesses, and matched warm cycles. No gameplay or standard-suite acceptance.
Fixtures must have separately closed free-QEMU/control self-checks.
"""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt
spec=importlib.util.spec_from_file_location('native_dispatch',REPO/'verif/sys/run-native-system.py')
native=importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('control','candidate','fixtures','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    args=parser.parse_args()
    assert __debug__
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve()==scratch and args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models={name:getattr(args,name).resolve(strict=True) for name in ('control','candidate')}
    profiles=[]
    pins={}
    for model in models.values():
        stamp=model.parent/'Vventium_top__verFiles.dat'
        command=next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
        assert ' --assert ' in command
        defs=set(re.findall(r'\+define\+(\w+)',command))
        assert {'VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC','VEN_PIPE_SDISPATCH',
                'VEN_PIPE_SDISPATCH_SHORT','VEN_L1_AXI','VEN_IC_BRAM','VEN_FE_PIPE'}<=defs
        assert not {'VEN_SYS_FASTPATH_ALL','VEN_UOPCACHE','SYNTHESIS','VTM_NO_DPI'}&defs
        profiles.append(defs)
        pins.update({str(p):sha(p) for p in (model,stamp)})
    assert profiles[0]==profiles[1]
    fixture_receipt=args.fixtures/'fixture-closed.json'
    prior=json.loads(fixture_receipt.read_text())
    assert prior['passed'] and prior['inputs_unchanged'] and len(prior['cases'])==16
    assert prior['pins'][str(HERE/'system-dispatch.S')]==sha(HERE/'system-dispatch.S')
    assert sha(models['control']) in prior['pins'].values()
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__),fixture_receipt,HERE/'system-dispatch.S',qemu,
              REPO/'verif/qemu-trace/gen_trace.py',REPO/'verif/diff/compare.py',
              REPO/'verif/diff/tracefmt.py',REPO/'verif/sys/run-native-system.py'):
        pins[str(p)]=sha(p)
    cases=[(k,r,o) for k in range(4) for r in (0,1) for o in (0,31)]
    for k,r,o in cases:
        for ext in ('bin','elf'):
            p=args.fixtures/f'control-k{k}-r{r}-o{o}'/('fixture.'+ext)
            pins[str(p)]=sha(p)
    (args.out/'inputs.json').write_text(json.dumps(pins,indent=2)+'\n')
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(args.out),PYTHONDONTWRITEBYTECODE='1')
    def run(command,leaf,name,expected=0,latency=0):
        command=['timeout','--kill-after=3s','60s',*map(str,command)]
        (leaf/(name+'.command.json')).write_text(json.dumps(command,indent=2)+'\n')
        with (leaf/(name+'.stdout')).open('x') as out,(leaf/(name+'.stderr')).open('x') as err:
            code=subprocess.run(command,env=dict(env,AXI_RLAT=str(latency),AXI_WLAT=str(latency)),
                                stdout=out,stderr=err).returncode
        (leaf/(name+'.exit')).write_text(str(code)+'\n')
        assert code==expected,(name,code,expected)
        return code
    def check(case):
        k,r,o=case
        leaf=args.out/f'k{k}-r{r}-o{o}'; leaf.mkdir()
        fixture=args.fixtures/f'control-k{k}-r{r}-o{o}'
        image,elf=fixture/'fixture.bin',fixture/'fixture.elf'
        symbols={p[2]:int(p[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                 if len(p:=line.split())==3}
        assert image.stat().st_size==65536 and symbols['hot_loop']%32==o
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
        run([sys.executable,'-B',REPO/'verif/qemu-trace/gen_trace.py','--qemu',qemu,'--system',
             '--image',image,'--image-mode','bios','--cpu','pentium','--out',leaf/'golden.vtrace',
             '--max-insn','2000','--port',str(port)],leaf,'golden')
        results=[]
        for latency in (0,7):
            measured={}
            for name,tb in models.items():
                traces={}
                for mode in ('cycle-func','cycle'):
                    stem=f'{name}-lat{latency}-{mode}'
                    path=leaf/(stem+'.vtrace')
                    rc=run([tb,'--system','--cosim','--'+mode,'--l1-axi','--image',image,
                        '--out',path,'--max-insn','2000','--max-cycles','1000000','--quiesce','4096',
                        '+ven_fetchdbg','+ven_fetchdbg_max=10000'],leaf,stem,133,latency)
                    parsed=tracefmt.read_trace(str(path)); traces[mode]=parsed.records
                    log=(leaf/(stem+'.stdout')).read_text()
                    if mode=='cycle-func':
                        native.grade_native(parsed,log,(leaf/(stem+'.stderr')).read_text(),rc,133,2000)
                        run([sys.executable,'-B',REPO/'verif/diff/compare.py','--mode','func','--all',
                             '--max-report','8',leaf/'golden.vtrace',path],leaf,stem+'-diff')
                rows=traces['cycle']
                assert [x['pc'] for x in rows]==[x['pc'] for x in traces['cycle-func']]
                hits=[i for i,x in enumerate(rows) if int(x['pc'],16)==symbols['hot_loop']]
                assert len(hits)==10
                pairs=[x for x in rows if int(x['pc'],16)==symbols['pair_v'] and x.get('pipe')=='V' and x.get('paired')]
                assert len(pairs)==10
                warm=[rows[b]['cyc']-rows[a]['cyc'] for a,b in zip(hits[2:-1],hits[3:])]
                target=f'eip={symbols["hot_loop"]:08x} flin={(r<<28)+symbols["hot_loop"]:08x} sys=1 '
                offers=sum('[FETCHDBG:SDISPATCH] '+target in line for line in log.splitlines())
                measured[name]=dict(warm_cycles=warm,paired_v=len(pairs),dispatches=offers)
            a,b=measured['control'],measured['candidate']
            if k==3:
                assert b['dispatches']==0 and b['warm_cycles']==a['warm_cycles'],('excluded CL shift',measured)
            else:
                assert b['dispatches']==10 and all(y<x for x,y in zip(a['warm_cycles'],b['warm_cycles'])),measured
            results.append(dict(kind=k,reloc=r,offset=o,latency=latency,measurements=measured))
        return results
    result=dict(passed=False,gameplay_ipc=None,standard_suite=False,cases=[],errors=[])
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            pending={pool.submit(check,c):c for c in cases}
            for future in concurrent.futures.as_completed(pending):
                try: result['cases'].extend(future.result())
                except Exception as exc: result['errors'].append(dict(case=pending[future],error=str(exc)))
        result['passed']=not result['errors']
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        (args.out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='cases'},indent=2))
    assert result['passed']

if __name__=='__main__':
    main()
