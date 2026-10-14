"""Bound one synthesis-only full-L1 tag-bank comparison; no CPU Fmax claim."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
import traceback

REPO=Path(__file__).resolve().parents[1]
SCRATCH=Path('/home/yukidama/external/tmp').resolve(strict=True)
GIB=1024**3
UNIT='ventium-way-tags-probe-oct14-r1.service'
SCOPE='ventium-vivado.scope'


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def load(path):
    return json.loads(path.read_text())


def save(path,value):
    with path.open('x') as f:
        json.dump(value,f,indent=2)


def state():
    return dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show',SCOPE,'-p','ActiveState','-p','InvocationID',
        '-p','ControlGroup','-p','MemoryMax','-p','MemorySwapMax','-p','TasksMax'],text=True,timeout=5).splitlines())


def host():
    return {line.split()[0].rstrip(':'):int(line.split()[1])*1024
        for line in Path('/proc/meminfo').read_text().splitlines()
        if line.startswith(('MemAvailable:','SwapFree:'))}


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',required=True,type=Path)
    args=ap.parse_args()
    data=SCRATCH/'ventium-data-size.v2HaTO2X'
    root=args.out.resolve()
    cache=data/'way-banked-tag-cache-r1'
    source=data/'fp-compare-fpga-r1'
    assert __debug__ and root==data/'way-banked-tag-probe-r1' and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==SCRATCH
    assert SCRATCH.stat().st_dev != REPO.stat().st_dev
    assert os.sched_getaffinity(0)=={16,17,18,19}
    invocation=subprocess.check_output(['systemctl','--user','show',UNIT,'-p','InvocationID','--value'],text=True).strip()
    assert invocation==os.environ['INVOCATION_ID']
    assert state()['ActiveState'] in ('inactive','failed')
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode==1
    assert shutil.disk_usage(SCRATCH).free>5*GIB
    assert host()['MemAvailable']>10*GIB and host()['SwapFree']>4*GIB
    checked=load(cache/'audit.json')
    assert checked['passed'] and checked['samples']==747037 and checked['rejected_mutations']==2
    manifest=load(source/'input-manifest.json')
    assert sha(source/'input-manifest.json')=='296ff7367ef6af0324c47a09615f09f2c02a700a3de411efc617f598c03c001b'
    definitions=(source/'defines.txt').read_text().splitlines()
    assert definitions==manifest['hardware_defines'] and len(definitions)==158
    assert sha(cache/'positive/ven_l1d.sv')==checked['source_sha256']=='62d3332d4d044efe022acce33eaa99b16e9a36da7a43e4afeda0b0265baeb3f3'
    parent=source/'ventium/rtl/mem/ven_l1d.sv'
    assert sha(parent)=='9b888b991ffc38034899f3c9e98bc1e04f9d37268aaba57cf13e1c0495428311'
    pins=dict(checked['pins'])
    for row in manifest['files']:
        pins[str(source/row['frozen'])]=row['sha256']
    for p in (Path(__file__).resolve(),cache/'audit.json',source/'input-manifest.json',source/'defines.txt',
              REPO/'fpga/inspect_way_banked_tags.tcl',REPO/'fpga/run_vivado_exclusive.sh',REPO/'tools/build_scope.sh'):
        pins[str(p)]=sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    root.mkdir()
    (root/'tool-tmp').mkdir()
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VENTIUM_','TB_','AXI_'))}
    env.update(TMPDIR=str(root/'tool-tmp'),VENTIUM_VIVADO_MEMORY_MAX='8G',
               VENTIUM_VIVADO_MEMORY_SWAP_MAX='2G',VENTIUM_VIVADO_LOCK_DIR=str(SCRATCH))
    tcl=REPO/'fpga/inspect_way_banked_tags.tcl'
    command=['timeout','--signal=TERM','--kill-after=30s','10m',str(REPO/'fpga/run_vivado_exclusive.sh'),
        '-mode','batch','-log',str(root/'native.log'),'-journal',str(root/'native.jou'),
        '-source',str(tcl),'-tclargs',str(parent),str(cache/'positive/ven_l1d.sv'),
        str(parent.parent),str(source/'defines.txt'),str(root/'reports')]
    save(root/'started.json',dict(pins=pins,command=command,controller_invocation=invocation,
        definitions=definitions,affinity=sorted(os.sched_getaffinity(0)),memory_max=8*GIB,
        swap_max=2*GIB,disk_floor=4*GIB,whole_core=False,cpu_fmax=None,hardware_acceptance=False))
    owner=None
    reason=None
    failure=None
    peak=swap_peak=0
    interrupted=False
    def interrupt(signum,frame):
        nonlocal interrupted
        interrupted=True
    signal.signal(signal.SIGTERM,interrupt)
    signal.signal(signal.SIGINT,interrupt)
    def stop(sig):
        now=state()
        if now['ActiveState'] in ('inactive','failed'):
            return
        assert owner and now['InvocationID']==owner['InvocationID']
        subprocess.run(['systemctl','--user','kill','--kill-whom=all','--signal='+sig,SCOPE],check=True,timeout=10)
    begin=time.monotonic()
    with (root/'guard.log').open('x') as log,(root/'watch.jsonl').open('x') as watch:
        child=subprocess.Popen(command,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
        try:
            while child.poll() is None:
                current=state()
                if current['ActiveState']=='active':
                    group=Path('/sys/fs/cgroup'+current['ControlGroup'])
                    if not group.exists():
                        time.sleep(.1)
                        continue
                    tasks=[]
                    for pid in (group/'cgroup.procs').read_text().split():
                        try:
                            p=Path('/proc')/pid
                            tasks.append(dict(pid=int(pid),argv=(p/'cmdline').read_bytes().rstrip(b'\0').decode().split('\0'),
                                affinity=sorted(os.sched_getaffinity(int(pid)))))
                        except (FileNotFoundError,ProcessLookupError):
                            pass
                    if owner is None and any(str(tcl) in p['argv'] for p in tasks):
                        assert current['MemoryMax']==str(8*GIB) and current['MemorySwapMax']==str(2*GIB)
                        assert current['TasksMax']=='48'
                        owner=current
                    if owner:
                        assert current['InvocationID']==owner['InvocationID']
                        assert all(set(p['affinity'])<={16,17,18,19} for p in tasks)
                        memory=int((group/'memory.current').read_text())
                        swap=int((group/'memory.swap.current').read_text())
                        events={k:int(v) for k,v in (line.split() for line in (group/'memory.events').read_text().splitlines())}
                        peak,swap_peak=max(peak,memory),max(swap_peak,swap)
                        available=host()
                        free=shutil.disk_usage(root).free
                        if interrupted: reason='controller signal'
                        elif free<4*GIB: reason='disk floor'
                        elif min(available.values())<2*GIB: reason='host reserve'
                        elif memory+swap>9*GIB: reason='combined memory early stop'
                        elif any(events[k] for k in ('oom','oom_kill','oom_group_kill')): reason='OOM'
                        watch.write(json.dumps(dict(seconds=time.monotonic()-begin,memory=memory,swap=swap,
                            events=events,disk_free=free,host=available,tasks=tasks,reason=reason))+'\n')
                        watch.flush()
                        if reason:
                            stop('TERM')
                            break
                elif interrupted:
                    raise RuntimeError('signal before native ownership')
                time.sleep(1)
        except BaseException:
            failure=traceback.format_exc()
            if owner: stop('TERM')
            else: child.terminate()
        try:
            code=child.wait(timeout=60)
        except subprocess.TimeoutExpired:
            stop('KILL')
            code=child.wait(timeout=20)
    stable=all(sha(p)==h for p,h in pins.items())
    native_log=(root/'native.log').read_text() if (root/'native.log').exists() else ''
    passed=code==0 and stable and owner is not None and not reason and not failure and '\nWAY_BANKED_TAG_SYNTHESIS_OK\n' in native_log
    result=dict(passed=passed,native_exit=code,pins_unchanged=stable,owner=owner,resource_stop=reason,
        controller_failure=failure,seconds=time.monotonic()-begin,memory_peak=peak,swap_peak=swap_peak,
        cpu_fmax=None,whole_core=False,routed=False,hardware_acceptance=False)
    save(root/'closed.json',result)
    print(json.dumps(result),flush=True)
    return 0 if passed else 1


if __name__=='__main__':
    raise SystemExit(main())
