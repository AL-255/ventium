#!/usr/bin/env python3
"""Bounded isolated DDR-bridge mapping, never a production build/deploy."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

REPO=Path(__file__).resolve().parents[1]
SCRATCH=Path('/home/yukidama/external/tmp')
SCOPE='ventium-vivado.scope'
GIB=1024**3
def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def state():
    result=subprocess.check_output(['systemctl','--user','show',SCOPE,'-p','ActiveState',
        '-p','InvocationID','-p','ControlGroup','-p','MemoryMax','-p','MemorySwapMax'],text=True,timeout=5)
    return dict(line.split('=',1) for line in result.splitlines() if '=' in line)
def available():
    return int(next(s.split()[1] for s in Path('/proc/meminfo').read_text().splitlines()
                    if s.startswith('MemAvailable:')))*1024
def save(root,name,data):
    with (root/name).open('x') as f:json.dump(data,f,indent=2)
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,required=True)
    args=parser.parse_args()
    assert state().get('ActiveState') in ('inactive','failed'),'refuse to preempt an active Vivado scope'
    # The exclusive launcher still enforces the mandatory single-family rule.
    # Refuse a separately launched Vivado as well rather than killing useful work.
    processes=subprocess.check_output(['ps','-eo','comm='],text=True).splitlines()
    assert not any(x.strip().lower()=='vivado' for x in processes),'live Vivado exists'
    assert SCRATCH.resolve()==Path(os.environ['TMPDIR']).resolve()
    assert available()>10*GIB and shutil.disk_usage(SCRATCH).free>3*GIB
    root=Path(tempfile.mkdtemp(prefix='ventium-posted-physical.',dir=SCRATCH)).resolve()
    inputs=root/'inputs';inputs.mkdir();(root/'tmp').mkdir()
    sources={'serial.v':args.baseline.resolve(strict=True),
             'posted.sv':REPO/'fpga/ven_ddram_axi_posted.sv',
             'inspect.tcl':REPO/'fpga/inspect_posted_leaf.tcl'}
    pins={}
    for name,source in sources.items():
        pins[str(source)]=digest(source)
        target=inputs/name;shutil.copyfile(source,target)
        pins[str(target)]=digest(target)
        assert pins[str(source)]==pins[str(target)]
    for source in (Path(__file__).resolve(),REPO/'fpga/run_vivado_exclusive.sh',REPO/'tools/build_scope.sh'):
        pins[str(source)]=digest(source)
    save(root,'inputs.json',pins)
    env={k:v for k,v in os.environ.items() if not k.startswith(('VENTIUM_','VEN_','AXI_','TB_'))}
    env.update(TMPDIR=str(root/'tmp'),PYTHONDONTWRITEBYTECODE='1',VENTIUM_VIVADO_LOCK_DIR=str(SCRATCH),
               VENTIUM_VIVADO_MEMORY_MAX='8G',VENTIUM_VIVADO_MEMORY_SWAP_MAX='0')
    script=inputs/'inspect.tcl'
    command=['timeout','--signal=TERM','--kill-after=15s','600s',str(REPO/'fpga/run_vivado_exclusive.sh'),
             '-mode','batch','-source',str(script),'-log',str(root/'native.log'),'-journal',str(root/'native.jou'),
             '-tclargs',str(inputs),str(root/'reports')]
    save(root,'command.json',command)
    print(root,flush=True)
    owner=None;peak=0;reason=None;events={}
    with (root/'guard.log').open('x') as log:
        proc=subprocess.Popen(command,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
        while proc.poll() is None:
            now=state()
            if now.get('ActiveState')=='active':
                cg=Path('/sys/fs/cgroup'+now['ControlGroup'])
                if owner is None:
                    for pid in (cg/'cgroup.procs').read_text().split():
                        try:argv=Path('/proc/'+pid+'/cmdline').read_bytes().split(b'\0')
                        except FileNotFoundError:continue
                        if str(script).encode() in argv:
                            assert now['MemoryMax']==str(8*GIB) and now['MemorySwapMax']=='0'
                            owner=now;break
                if owner:
                    assert now['InvocationID']==owner['InvocationID'],'owner changed'
                    try:
                        used=int((cg/'memory.current').read_text())
                        events=dict((k,int(v)) for k,v in (s.split() for s in (cg/'memory.events').read_text().splitlines()))
                    except FileNotFoundError:continue
                    peak=max(peak,used)
                    if used>=7*GIB or available()<2*GIB or shutil.disk_usage(root).free<2*GIB or events.get('oom',0):
                        reason='resource reserve'
                        subprocess.run(['systemctl','--user','kill','--kill-whom=all','--signal=TERM',SCOPE],check=True,timeout=5)
                        break
            time.sleep(.5)
        rc=proc.wait(timeout=630)
    stable=all(digest(Path(p))==h for p,h in pins.items())
    closed=dict(native_exit=rc,owner=owner,peak_bytes=peak,resource_stop=reason,oom_events=events,
                inputs_unchanged=stable,cpu_fmax_qualified=False,gameplay_ipc=None,standard_suite=False)
    save(root,'closed.json',closed)
    assert rc==0 and owner and reason is None and stable and not events.get('oom',0),closed
    assert state().get('ActiveState') in ('inactive','failed')
    report=(root/'reports/receipt.tsv').read_text()
    assert report.count('\n')==6 and 'COMPLETE CPU_FMAX_QUALIFIED=0 STANDARD_SUITE=0' in report
    print(report,flush=True)
    print('POSTED-LEAF-MAPPING-CLOSED; not full-system qualification',flush=True)
if __name__=='__main__':main()
