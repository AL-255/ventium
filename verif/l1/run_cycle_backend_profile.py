"""Quantify existing cycle failures without changing the RTL or timing gate."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt
PARENT=Path('/home/yukidama/external/tmp/ventium-frndint.tM8XCg6d/core-r1')
MODEL='2050b71430b39fc5059a8f2be6beeae74e232b279d21b2b0541a1e16b7d35d63'
NAMES=('mb_fpindep','mb_faddchain','mb_depadd','mb_indepadd','mb_dmiss','mb_imiss','mb_brloop','mb_brrandom')


def sha(p):
    with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def load(p):return json.loads(p.read_text())
def save(p,d):
    with p.open('x') as f:json.dump(d,f,indent=2)


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path,required=True)
    a=ap.parse_args();root=a.out.resolve();scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert os.sched_getaffinity(0)==set(range(8,16)) and os.environ['INVOCATION_ID']
    assert Path(os.environ['TMPDIR']).resolve()==scratch and shutil.disk_usage(scratch).free>4*1024**3+150*1024**2
    core=PARENT.resolve(strict=True);work=core/'generic-work';built=load(core/'build-closed.json')
    assert built['passed'] and built['pins_unchanged'] and sha(core/'obj/tb_ventium')==MODEL
    pins={str(p):sha(p) for p in (Path(__file__),core/'obj/tb_ventium',core/'build-closed.json',
        core/'build-started.json',core/'obj/Vventium_top__verFiles.dat',
        REPO/'verif/diff/tracefmt.py',REPO/'verif/diff/compare.py')}
    started=load(core/'build-started.json')
    for p in (core/'candidate').rglob('*'):
        if p.is_file():
            assert sha(p)==started['pins'][str(p)];pins[str(p)]=sha(p)
    host=Path(started['host']);pins[str(host)]=sha(host)
    assert "axr_lat = AXI_RLAT + g;" in host.read_text()
    assert '-GAXI_LINE_REPLAY' not in (core/'obj/Vventium_top__verFiles.dat').read_text()
    assert "parameter bit AXI_LINE_REPLAY = 1'b1" in (core/'candidate/rtl/ventium_top.sv').read_text()
    jobs=[]
    for name in NAMES:
        args=[s.decode() for s in (work/(name+'.cycle_rtl.argv')).read_bytes().split(b'\0') if s]
        assert args[0]==str(core/'obj/tb_ventium') and '--cycle' in args and '--l1-axi' in args
        assert not any(x in args for x in ('--cycle-func','--dbg-step','--dbg-bp','--no-trace'))
        gold=Path((work/(name+'.cycle.result')).read_text().split('|')[5])
        expected=tracefmt.read_trace(str(work/(name+'.cycle_rtl.vtrace'))).records
        for p in (work/(name+'.cycle_rtl.argv'),work/(name+'.cycle_rtl.vtrace'),
                  work/(name+'.cycle.result'),Path(args[args.index('--image')+1]),gold):pins[str(p)]=sha(p)
        for latency in (0,1,7):jobs.append((name,latency,args,gold,expected))
    root.mkdir();save(root/'started.json',dict(pins=pins,model=MODEL,invocation=os.environ['INVOCATION_ID'],
        line_replay=1,latencies=[0,1,7],jobs=len(jobs),workers=8,hardware_equivalent=False))
    def run(index_job):
        index,(name,latency,oldargs,gold,expected)=index_job;cpu=8+index%8
        label=name+'-lat'+str(latency);out=root/(label+'.vtrace');log=root/(label+'.log')
        args=oldargs.copy();args[args.index('--out')+1]=str(out)
        command=['taskset','-c',str(cpu),*args]
        env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_','VERIFY_'))}
        env.update(TMPDIR=str(root),AXI_RLAT=str(latency),AXI_WLAT=str(latency),VEN_AXI_PROFILE='1')
        observed=[];begin=time.monotonic()
        with log.open('x') as f:
            child=subprocess.Popen(command,env=env,stdout=f,stderr=subprocess.STDOUT)
            while child.poll() is None:
                try:
                    # Popen first launches taskset with the owner's CPU set;
                    # sample the actual model after taskset has exec'd it.
                    if (Path('/proc')/str(child.pid)/'exe').readlink().name=='tb_ventium':
                        observed.append(sorted(os.sched_getaffinity(child.pid)))
                except (FileNotFoundError,ProcessLookupError):pass
                if time.monotonic()-begin>90:
                    child.kill();child.wait();raise TimeoutError(label)
                time.sleep(.001)
            code=child.wait()
        assert code==0 and observed and all(v==[cpu] for v in observed)
        t=tracefmt.read_trace(str(out));records=t.records;txt=log.read_text()
        assert [r['pc'] for r in records]==[r['pc'] for r in expected]
        if latency==7:assert records==expected, 'profiling must be passive'
        assert '--l1-axi selected' in txt and '[fault-deliveries] actual=0' in txt
        profile=re.search(r'\[AXI_PROFILE\] read ar=(\d+) line-ar=(\d+) requested=(\d+) r=(\d+) rlast=(\d+) incomplete=(\d+) overlap=(\d+) orphan-r=(\d+) valid=(\d+)',txt)
        assert profile and profile.groups()[5:]==('0','0','0','1')
        axi=dict(zip(('ar','line_ar','requested','r','rlast','incomplete','overlap','orphan_r','valid'),map(int,profile.groups())))
        avg=re.search(r'\[AXI_PROFILE\] read avg-busy=([\d.]+) ar-to-first-r-hs=([\d.]+) nontransfer=([\d.]+) rvalid-low-total=(\d+) rready-stall=(\d+)',txt)
        assert avg
        axi.update(zip(('avg_busy','first_r_hs','nontransfer','rvalid_low','rready_stall'),map(float,avg.groups())))
        pairs=int(re.search(r'pairedV=(\d+)',txt).group(1))
        assert pairs==sum(r['pipe']=='V' for r in records) and pairs>0
        passes=[]
        if name=='mb_fpindep':
            boundaries=[i for i,r in enumerate(records) if r['pc']=='0x08048005'];assert len(boundaries)==4
            for first,last in zip(boundaries,boundaries[1:]):
                clocks=records[last]['cyc']-records[first]['cyc']
                passes.append(dict(first=first,last=last,retirements=last-first,clocks=clocks,cpi=clocks/(last-first)))
        compare_command=[sys.executable,'-B',str(REPO/'verif/diff/compare.py'),'--mode','cycle',str(gold),str(out)]
        with (root/(label+'.compare.log')).open('x') as f:
            compare_exit=subprocess.run(compare_command,stdout=f,stderr=subprocess.STDOUT,timeout=30).returncode
        assert compare_exit in (0,1)
        row=dict(name=name,latency=latency,native_exit=code,affinity=[cpu],affinity_observed=True,
            command=command,environment={k:env[k] for k in ('AXI_RLAT','AXI_WLAT','VEN_AXI_PROFILE')},
            records=len(records),clocks=records[-1]['cyc'],cpi=records[-1]['cyc']/len(records),
            paired_v=pairs,axi=axi,fp_passes=passes,cycle_comparator_exit=compare_exit,
            passive_trace_equal=latency==7,seconds=time.monotonic()-begin,
            trace_sha256=sha(out),log_sha256=sha(log))
        save(root/(label+'.closed.json'),row);return row
    begin=time.monotonic()
    with ThreadPoolExecutor(max_workers=8) as pool:rows=list(pool.map(run,enumerate(jobs)))
    stable=all(sha(p)==h for p,h in pins.items())
    cg=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
    events=dict(s.split() for s in (cg/'memory.events').read_text().splitlines())
    assert stable and events['oom']==events['oom_kill']=='0'
    result=dict(diagnostic_completed=True,pins_unchanged=stable,rows=rows,seconds=time.monotonic()-begin,
        memory_events=events,canonical_gate_passed=False,rtl_changes=False,standard_suite=False,
        hardware_acceptance=False,gameplay_ipc=None)
    save(root/'closed.json',result)
    print(json.dumps({**result,'rows':[{k:r[k] for k in ('name','latency','clocks','cpi','paired_v','axi','fp_passes','cycle_comparator_exit')} for r in rows]},indent=2))


if __name__=='__main__':main()
