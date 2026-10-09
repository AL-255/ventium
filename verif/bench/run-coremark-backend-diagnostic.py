#!/usr/bin/env python3
"""Short, ordinary-RAM CoreMark CRC and backend diagnostic. NOT a score gate.

Run in a 2-GiB, zero-swap, 160-task cgroup with affinity 2,3. Reuses unchanged
QEMU-loaded 10-iteration entry images, not relocated bytes or restored work.
"""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

REPO=Path(__file__).resolve().parents[2]
sys.path[:0]=[str(REPO/'tools'),str(REPO/'verif/sys')]
import run_coremark_matrix as matrix
import check_faultlog


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def save(p,v):
    with p.open('x') as f:json.dump(v,f,indent=2)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('binary','build-receipt','images','out'):ap.add_argument('--'+name,type=Path,required=True)
    ap.add_argument('--binary-sha256',required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch)
    assert sorted(os.sched_getaffinity(0))==[2,3]
    envelope=matrix.simulation_envelope()
    assert envelope and envelope['memory_max_bytes']==2*1024**3 and envelope['tasks_max']==160
    cg=Path(envelope['cgroup']);assert (cg/'memory.swap.max').read_text().strip()=='0'
    assert sha(args.binary)==args.binary_sha256
    pins=dict(json.loads(args.build_receipt.read_text())['pins'])
    image_receipt=json.loads((args.images/'closed.json').read_text())
    assert image_receipt['passed']
    pins.update(image_receipt['pins'])
    stamp=args.binary.parent/'Vventium_top__verFiles.dat'
    command=next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
    defs=set(re.findall(r'\+define\+(\w+)',command))
    assert ' --assert ' in command
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT','VEN_P54_INT_EXEC_OCC'}<=defs
    assert not {'VEN_UOPCACHE','VEN_KV260_SOC','VTM_NO_DPI','SYNTHESIS','VEN_SYS_FASTPATH_ALL'}&defs
    for p in (Path(__file__),args.binary,args.build_receipt,stamp,args.images/'closed.json',
              REPO/'tools/run_coremark_matrix.py',REPO/'verif/sys/check_faultlog.py'):
        pins[str(p)]=sha(p)
    workloads=[]
    for seed,crc in (('performance','fcaf'),('validation','c64e')):
        image=(args.images/seed/'entry.image.json').resolve(strict=True)
        assert sha(image)==next(w for w in image_receipt['workloads'] if w['seed']==seed)['image_sha256']
        pins[str(image)]=sha(image)
        workloads.append(dict(seed=seed,iterations=10,image=str(image),crcfinal=crc))
    assert all(sha(p)==h for p,h in pins.items())
    args.out.mkdir()
    save(args.out/'plan.json',dict(pins=pins,envelope=envelope,workloads=workloads,
                                 binary_sha256=args.binary_sha256,score_eligible=False,standard_suite=False))
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(args.out),PYTHONDONTWRITEBYTECODE='1',TB_CLOCK_CYCLE_PROBE='1',
               AXI_RLAT='0',AXI_WLAT='0')
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,matrix.stop_children)

    def run(workload,cpu,axi):
        out=args.out/(workload['seed']+('-axi' if axi else '-direct'));out.mkdir()
        argv=['taskset','-c',str(cpu),str(args.binary),'--quake-image',workload['image'],
              '--emulate-syscalls','--no-trace','--cycle','--max-insn','4000000',
              '--max-cycles','25000000','--quiesce','200000','--user-stdout',str(out/'guest.stdout'),
              '+ven_faultlog',*(['--l1-axi'] if axi else [])]
        save(out/'command.json',dict(argv=argv,started=time.time(),environment={k:env[k] for k in
             ('TB_CLOCK_CYCLE_PROBE','AXI_RLAT','AXI_WLAT')}))
        start=time.monotonic()
        with (out/'run.log').open('x') as log,(out/'run.stderr').open('x') as err:
            proc=subprocess.Popen(argv,stdout=log,stderr=err,env=env,start_new_session=True)
            with matrix._children_lock:matrix._children.add(proc)
            try:rc=proc.wait(timeout=180)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid,signal.SIGTERM)
                try:rc=proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid,signal.SIGKILL);rc=proc.wait()
            finally:
                with matrix._children_lock:matrix._children.discard(proc)
        canonical=(out/'run.log').read_text()
        log=canonical+'\n'+(out/'run.stderr').read_text()
        stdout=(out/'guest.stdout').read_text() if (out/'guest.stdout').exists() else ''
        result=matrix.parse_result(log,stdout,workload,dict(nr=403,clock_id=0),False)
        acks=re.findall(r'\[L1DPERF\] fill cycles=\d+ backing-wait=\d+ backing-ack=(\d+)',log)
        paired=re.findall(r'retires\s+(\d+)\s+\(U=(\d+)\s+pairedV=(\d+)\)',log)
        result.update(native_exit=rc,seconds=time.monotonic()-start,axi=axi,seed=workload['seed'],
                      short_diagnostic_only=True,standard_suite=False,gameplay_ipc=None)
        result['backend_witness']=len(acks)==1 and ((int(acks[0])>0)==axi)
        result['paired_v_witness']=len(paired)==1 and int(paired[0][2])>0 and int(paired[0][0])==sum(map(int,paired[0][1:]))
        check_faultlog.check_counts(check_faultlog.read_counts(canonical.splitlines()),{})
        result['no_fault_log']=not re.search(r'%Error|%Fatal|Assertion failed|tb: FLT',log)
        assert re.findall(r'^ERROR!.*$',stdout,re.M)==['ERROR! Must execute for at least 10 secs for a valid result!']
        assert log.count('tb: [store-policy] backend=MemModel u=1 v=1 address-mask=ffffffff ram-top=00000000 option-rom=0')==1
        if axi:assert 'bypass-start=0' in log
        result['passed']=rc==0 and all(result.get(k,False) for k in
            ('complete','crc_ok','iterations_ok','dataset_ok','backend_witness','paired_v_witness','no_fault_log'))
        assert not result['score_eligible']
        save(out/'result.json',result)
        print(json.dumps({k:result.get(k) for k in ('passed','seed','axi','native_exit','clocks','retired',
            'crc_ok','cm_per_mhz_total_program','score_eligible','seconds')}),flush=True)
        return result

    result=dict(passed=False,results=[],errors=[],score_eligible=False,standard_suite=False,gameplay_ipc=None)
    try:
        for axi in (False,True):
            with ThreadPoolExecutor(max_workers=2) as pool:
                rows=list(pool.map(lambda pair:run(pair[0],pair[1],axi),zip(workloads,(2,3))))
            result['results']+=rows
            assert all(r['passed'] for r in rows)
        result['passed']=len(result['results'])==4
    except Exception as exc:result['errors'].append(repr(exc))
    finally:
        result['inputs_unchanged']=all(sha(p)==h for p,h in pins.items())
        result['memory_events']=dict(line.split() for line in (cg/'memory.events').read_text().splitlines())
        result['all_children_reaped']=not matrix._children
        result['passed'] &= result['inputs_unchanged'] and result['all_children_reaped'] and all(
            result['memory_events'][k]=='0' for k in ('oom','oom_kill'))
        save(args.out/'closed.json',result)
    assert result['passed'],result['errors']


if __name__=='__main__':main()
