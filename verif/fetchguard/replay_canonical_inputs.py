"""Replay the parent on the candidate's exact canonical native inputs.

Cold QEMU runs can establish different initial ESP values (including because
the executable path length changes). Comparing those two native traces is not
an A/B experiment. Do NOT mask ESP or normalize records: reuse the candidate's
actual flattened image and cached golden-derived initial ESP, then compare
every architectural field. Canonical failures remain failures.
"""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time
import traceback

import run_probe_boundary_ab as boundary

REPO=Path(__file__).resolve().parents[2]
native,tracefmt,sha=boundary.native,boundary.tracefmt,boundary.sha


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('parent','candidate','out'): ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args(); parent,candidate=a.parent.resolve(strict=True),a.candidate.resolve(strict=True); out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    assert os.sched_getaffinity(0)==set(range(32)) and os.environ['INVOCATION_ID']
    pins={}; models={}
    for label,folder in [('parent',parent),('candidate',candidate)]:
        b=json.loads((folder/'build-closed.json').read_text()); v=json.loads((folder/'verify-closed.json').read_text())
        assert b['passed'] and b['pins_unchanged'] and v['pins_unchanged']
        assert not v['masks_or_goldens_or_bands_changed']
        assert sha(folder/'obj/tb_ventium')==b['binary_sha256']
        models[label]=folder/'obj/tb_ventium'
        for p in (folder/'build-closed.json',folder/'verify-closed.json',models[label]): pins[str(p)]=sha(p)
    start=json.loads((candidate/'verify-started.json').read_text())
    assert start['environment']['TB_EXTRA_FLAGS']=='--cycle-func --l1-axi'
    assert start['environment']['AXI_RLAT']==start['environment']['AXI_WLAT']=='7'
    work,cache=candidate/'generic-work',candidate/'generic-cache'
    jobs=[s.split('\t') for s in (work/'jobs.txt').read_text().splitlines() if s.startswith('func\t')]
    assert len(jobs)==108
    inputs=[]
    for job in jobs:
        _,name,source,load,entry,limit,x87,*_=job
        source=Path(source); elf=work/(name+'.func.elf'); flat=work/(name+'.func.flat')
        source_hash=hashlib.sha1(source.read_bytes()).hexdigest()
        elf_hash=hashlib.sha1(elf.read_bytes()).hexdigest()[:12]
        golds=list(cache.glob(f'{source_hash}.{elf_hash}.*.func.preexit0.x87{x87}.max{limit}.vtrace'))
        assert len(golds)==1,(name,golds)
        gold=tracefmt.read_trace(str(golds[0])); assert gold.records
        inputs.append(dict(name=name,image=str(flat),load=load,entry=entry,limit=limit,x87=x87,
                           esp=gold.records[0]['esp'],trace=str(work/(name+'.func_rtl.vtrace'))))
        for p in (source,elf,flat,golds[0],work/(name+'.func_rtl.vtrace')): pins[str(p)]=sha(p)
    for p in (Path(__file__),Path(native.__file__),Path(tracefmt.__file__),REPO/'verif/lib/verify_worker.sh',
              candidate/'verify-started.json',work/'jobs.txt'): pins[str(p)]=sha(p)
    out.mkdir()
    def save(p,v):
        with p.open('x') as f: json.dump(v,f,indent=2)
    save(out/'started.json',dict(pins=pins,inputs=inputs,invocation=os.environ['INVOCATION_ID'],workers=32,
                              comparison='complete unmodified architectural records',canonical_gate_passed=False))
    cpus=[i for i in range(32) if i!=11] # leave the live cold Quake CPU alone
    begin=time.monotonic(); rows=[]; errors=[]
    def case(item):
        index,r=item; folder=out/r['name']; folder.mkdir(); target=folder/'parent.vtrace'
        command=['env','AXI_RLAT=7','AXI_WLAT=7','taskset','-c',str(cpus[index%len(cpus)]),models['parent'],
                 '--image',r['image'],'--load',r['load'],'--entry',r['entry'],'--init-esp',r['esp'],
                 '--out',target,'--max-insn',r['limit']]
        if r['x87']=='1': command+=['--x87']
        command+=['--cycle-func','--l1-axi']
        receipt=native.supervise(list(map(str,command)),folder/'native.stdout',folder/'native.stderr',
                                folder/'native.exit.json',120)
        assert receipt['actual_wait'] and receipt['group_closed'] and receipt['actual_return_code']==0
        log=(folder/'native.stdout').read_text()+(folder/'native.stderr').read_text()
        assert not native.FATAL.search(log)
        old,new=tracefmt.read_trace(str(target)),tracefmt.read_trace(r['trace'])
        assert (old.mode,old.sys,old.x87)==(new.mode,new.sys,new.x87)
        assert old.records==new.records,('complete architectural mismatch',r['name'])
        return dict(name=r['name'],records=len(new.records),same_records=True,actual_init_esp=r['esp'],
                    native=receipt,trace_sha256=sha(target))
    with ThreadPoolExecutor(max_workers=32) as pool:
        futures=[pool.submit(case,item) for item in enumerate(inputs)]
        for future in futures:
            try: rows.append(future.result())
            except Exception as e: errors.append(dict(error=repr(e),traceback=traceback.format_exc()))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(regression_check_passed=stable and len(rows)==108 and not errors,rows=rows,errors=errors,
        pins_unchanged=stable,seconds=time.monotonic()-begin,canonical_gate_passed=False,
        masks_or_record_normalization=False,gameplay_ipc=None,standard_suite=False)
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'},indent=2),flush=True)
    return int(not result['regression_check_passed'])


if __name__=='__main__': raise SystemExit(main())
