"""Finish only the four high-latency SMM jobs, then regrade every native result.

The first attempt's 5M-cycle exit is retained as FAIL, never used as completion.
Latency-0/7 complete in 805452/1984977 cycles, suggesting about 6.03M at 31.
Use a bounded 8M-cycle / 180-second allowance and four parallel native jobs;
the unchanged guest must still reach exit 133 and every original witness.
"""
from concurrent.futures import ThreadPoolExecutor
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import time
import traceback

import run_early_bus_physical as original

sha,native,tracefmt=original.sha,original.native,original.tracefmt


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ('partial','parent','core','out'): ap.add_argument('--'+n,type=Path,required=True)
    a=ap.parse_args(); partial,parent,core=[getattr(a,n).resolve(strict=True) for n in ('partial','parent','core')]; out=a.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>5*1024**3
    assert os.sched_getaffinity(0)==set(range(17,21)) and os.environ['INVOCATION_ID']
    failed=json.loads((partial/'closed.json').read_text()); started=json.loads((partial/'started.json').read_text())
    assert not failed['passed'] and failed['pins_unchanged'] and len(failed['errors'])==1 and len(failed['rows'])==12
    cutoff=partial/'psmmmeta/parent-lat31-cycle-func'
    receipt=json.loads(cutoff.with_suffix('.exit.json').read_text())
    assert receipt['actual_return_code']==0 and receipt['actual_wait'] and receipt['group_closed'] and not receipt['timed_out']
    assert 'in 5000000 clocks' in cutoff.with_suffix('.stderr').read_text()
    assert 'isa-debug-exit reached' not in cutoff.with_suffix('.stderr').read_text()
    assert sha(core/'obj/tb_ventium')==original.identity.MODEL
    assert sha(parent/'obj/tb_ventium')==original.identity.builder.MODEL
    pins=dict(started['pins'])
    for p in (Path(__file__),Path(original.__file__),*(p for p in partial.rglob('*') if p.is_file())):
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    out.mkdir()
    def save(p,v):
        with p.open('x') as stream: json.dump(v,stream,indent=2)
    save(out/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],cycle_mode=1,
        debugger_step=False,snapshots=False,candidate=original.identity.MODEL,partial_retains_failed_verdict=True,
        native_cycle_limit=8000000,native_seconds=180,workers=4))
    begin=time.monotonic(); rows=[]; errors=[]
    def job(item):
        index,(label,model,mode)=item; tag=f'{label}-lat31-{mode}'
        command=['env','AXI_RLAT=31','AXI_WLAT=31','taskset','-c',str(17+index),model,
            '--system','--cosim','--'+mode,'--l1-axi','--image',partial/'psmmmeta/test.bin','--out',out/(tag+'.vtrace'),
            '--max-insn','60000','--max-cycles','8000000','--quiesce','4096']
        receipt=native.supervise(list(map(str,command)),out/(tag+'.stdout'),out/(tag+'.stderr'),out/(tag+'.exit.json'),180)
        assert receipt['actual_return_code']==133 and receipt['actual_wait'] and receipt['group_closed'],receipt
    jobs=[(label,folder/'obj/tb_ventium',mode) for label,folder in [('parent',parent),('candidate',core)]
          for mode in ('cycle-func','cycle')]
    try:
        with ThreadPoolExecutor(max_workers=4) as pool: list(pool.map(job,enumerate(jobs)))
        for name,limit in [('real-int',1000),('psmm',12000),('psmmmeta',60000)]:
            for latency in (0,7,31):
                both={}; clocks={}
                for label in ('parent','candidate'):
                    modes={}; counts={}
                    for mode in ('cycle-func','cycle'):
                        folder=out if name=='psmmmeta' and latency==31 else partial/name
                        tag=f'{label}-lat{latency}-{mode}'
                        receipt=json.loads((folder/(tag+'.exit.json')).read_text())
                        assert receipt['actual_return_code']==133 and receipt['actual_wait'] and receipt['group_closed']
                        assert not receipt['timed_out'] and not receipt['cleanup_signals']
                        for suffix in ('stdout','stderr'):
                            assert sha(folder/(tag+'.'+suffix))==receipt[suffix+'_sha256']
                        log=(folder/(tag+'.stdout')).read_text()+(folder/(tag+'.stderr')).read_text()
                        assert not native.FATAL.search(log) and 'isa-debug-exit reached' in log
                        trace=tracefmt.read_trace(str(folder/(tag+'.vtrace')))
                        assert 0<len(trace.records)<limit
                        counts[mode]=int(re.search(r'after \d+ retired in (\d+) clocks',log)[1])
                        modes[mode]=trace.records
                        if mode=='cycle-func':
                            original.grade(name,trace.records,folder/(tag+'.json'))
                            if name=='real-int':
                                gold=tracefmt.read_trace(str(partial/name/'gold.vtrace'))
                                with (out/(tag+'-rm.diff.log')).open('x') as stream:
                                    assert original.compare.compare_func(gold,trace,False,0xffffffff,False,20,stream,sys_both=True)==0
                    assert counts['cycle']==counts['cycle-func']
                    paired=sum(r.get('pipe')=='V' and r.get('paired') for r in modes['cycle'])
                    assert paired>0
                    both[label]=modes; clocks[label]=counts
                    rows.append(dict(case=name,label=label,latency=latency,records=len(modes['cycle']),
                                     clocks=counts['cycle'],paired_v=paired))
                assert both['parent']==both['candidate'] and clocks['parent']==clocks['candidate']
    except Exception as e: errors.append(dict(error=repr(e),traceback=traceback.format_exc()))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=stable and len(rows)==18 and not errors,rows=rows,errors=errors,pins_unchanged=stable,
        seconds=time.monotonic()-begin,canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,
        gameplay_ipc=None,original_cycle_cap_failure_waived=False)
    save(out/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'},indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__': raise SystemExit(main())
