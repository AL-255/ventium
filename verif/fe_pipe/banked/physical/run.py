#!/usr/bin/env python3
"""Freeze or run the isolated banked mapping/primitive-model check.

Preparation never starts Vivado. Execution refuses a live Vivado scope rather
than invoking the exclusive launcher's intentional replacement behavior.
Neither mode changes a production project, bitstream or board.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
SCRATCH = Path('/home/yukidama/external/tmp')
VENDOR = Path('/tools/Xilinx/2025.2/Vivado/data/verilog/src')
SCOPE = 'ventium-vivado.scope'
GIB = 1024**3

def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()

def save(root,name,value):
    with (root/name).open('x') as stream:
        json.dump(value,stream,indent=2);stream.write('\n')

def state():
    text = subprocess.check_output(['systemctl','--user','show',SCOPE,'-p','ActiveState',
        '-p','InvocationID','-p','ControlGroup','-p','MemoryMax','-p','MemorySwapMax'],text=True,timeout=5)
    return dict(line.split('=',1) for line in text.splitlines() if '=' in line)

def available():
    return int(next(line.split()[1] for line in Path('/proc/meminfo').read_text().splitlines()
                    if line.startswith('MemAvailable:')))*1024

def check_pins(pins):
    return all(digest(path)==expected for path,expected in pins.items())

def prepare():
    assert subprocess.check_output(['findmnt','-T',str(SCRATCH),'-no','FSTYPE'],text=True).strip()=='ext4'
    assert shutil.disk_usage(SCRATCH).free > 3*GIB
    root=Path(tempfile.mkdtemp(prefix='ventium-fe-banked-physical.',dir=SCRATCH)).resolve()
    inputs=root/'inputs';inputs.mkdir()
    sources={
        'banked64.sv':HERE.parent/'ven_fe_dtlb.sv',
        'control8.sv':HERE.parents[1]/'permission/ven_fe_dtlb.sv',
        'tb_fe_banked.sv':HERE.parent/'tb_fe_banked.sv',
        'tb_fe_banked_netlist.sv':HERE/'tb_fe_banked_netlist.sv',
        'inspect.tcl':HERE/'inspect.tcl',
    }
    pins={str(path):digest(path) for path in sources.values()}
    for name,source in sources.items():
        target=inputs/name
        shutil.copyfile(source,target)
        assert digest(target)==pins[str(source)]
        pins[str(target)]=digest(target)
    for path in (Path(__file__),REPO/'fpga/run_vivado_exclusive.sh',REPO/'tools/build_scope.sh',VENDOR/'glbl.v'):
        pins[str(path)]=digest(path)
    # Library lookup is done by iverilog, not by guessing which RAM primitives
    # Vivado will select. Pin every candidate library source before synthesis.
    for path in sorted((VENDOR/'unisims').glob('*.v')):
        pins[str(path)]=digest(path)
    assert check_pins(pins)
    save(root,'inputs.json',pins)
    save(root,'prepared.json',dict(native_started=False,profiles=['control8','banked64'],
        cpu_fmax_qualified=False,gameplay_ipc=None,standard_suite=False))
    print(root,flush=True)
    return root

def run(root):
    root=root.resolve(strict=True)
    assert root.parent==SCRATCH.resolve() and root.name.startswith('ventium-fe-banked-physical.')
    pins=json.loads((root/'inputs.json').read_text())
    assert check_pins(pins), 'prepared inputs changed'
    assert state().get('ActiveState') in ('inactive','failed'), 'do not preempt live Vivado'
    assert available()>10*GIB and shutil.disk_usage(root).free>3*GIB
    (root/'run.once').mkdir();(root/'tmp').mkdir()
    env={k:v for k,v in os.environ.items() if not k.startswith(('VENTIUM_','VEN_','AXI_','TB_'))}
    env.update(TMPDIR=str(root/'tmp'),PYTHONDONTWRITEBYTECODE='1',
        VENTIUM_VIVADO_LOCK_DIR=str(SCRATCH),VENTIUM_VIVADO_MEMORY_MAX='8G',VENTIUM_VIVADO_MEMORY_SWAP_MAX='0')
    script=root/'inputs/inspect.tcl'
    command=['timeout','--signal=TERM','--kill-after=15s','600s',str(REPO/'fpga/run_vivado_exclusive.sh'),
        '-mode','batch','-source',str(script),'-log',str(root/'native.log'),'-journal',str(root/'native.jou'),
        '-tclargs',str(root/'inputs'),str(root/'native-output')]
    save(root,'synthesis-command.json',command)
    owner=None;peak=0;reason=None
    with (root/'guard.log').open('x') as log:
        proc=subprocess.Popen(command,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
        while proc.poll() is None:
            current=state()
            if current.get('ActiveState')=='active':
                group=Path('/sys/fs/cgroup'+current['ControlGroup'])
                if owner is None:
                    for pid in (group/'cgroup.procs').read_text().split():
                        try: args=Path('/proc/'+pid+'/cmdline').read_bytes().split(b'\0')
                        except FileNotFoundError: continue
                        if str(script).encode() in args:
                            assert current['MemoryMax']==str(8*GIB) and current['MemorySwapMax']=='0'
                            owner=current;print(json.dumps(dict(event='owned',**owner)),flush=True);break
                if owner:
                    assert current['InvocationID']==owner['InvocationID'], 'owner changed'
                    try:
                        used=int((group/'memory.current').read_text())
                        events=dict((k,int(v)) for k,v in (s.split() for s in (group/'memory.events').read_text().splitlines()))
                    except FileNotFoundError: continue
                    peak=max(peak,used)
                    if used>=7*GIB or available()<2*GIB or shutil.disk_usage(root).free<2*GIB or events.get('oom',0):
                        reason='resource reserve'
                        subprocess.run(['systemctl','--user','kill','--kill-whom=all','--signal=TERM',SCOPE],check=True,timeout=5)
                        break
            time.sleep(.5)
        rc=proc.wait(timeout=630)
    save(root,'synthesis-closed.json',dict(native_exit=rc,owner=owner,peak_bytes=peak,
        resource_stop=reason,pins_unchanged=check_pins(pins),cpu_fmax_qualified=False))
    assert rc==0 and owner and reason is None and check_pins(pins)
    assert state().get('ActiveState') in ('inactive','failed')
    receipt=(root/'native-output/receipt.tcllist').read_text()
    assert 'COMPLETE PROFILES 2 CPU_ACCEPTANCE 0' in receipt
    # Use the vendor functional primitive models, not handwritten RAM stubs.
    post=root/'postsim';post.mkdir()
    def native(argv,stem,limit):
        save(root,stem+'-command.json',list(map(str,argv)))
        with (root/(stem+'.log')).open('x') as log:
            child=subprocess.Popen(argv,cwd=post,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            try: status=child.wait(timeout=limit)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGTERM)
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL);child.wait()
                status=124
        save(root,stem+'-closed.json',dict(native_exit=status))
        assert status==0,(stem,status)
    result=dict(passed=False,cpu_fmax_qualified=False,gameplay_ipc=None,standard_suite=False)
    try:
        for stage in ('synth','route'):
            net=root/f'native-output/banked64-{stage}.v'
            pins[str(net)]=digest(net)
            compile_command=['iverilog','-g2012','-s','tb_fe_banked_netlist','-s','glbl',
                '-y',VENDOR/'unisims','-I',VENDOR,'-M',f'all={post}/{stage}.deps',
                '-o',post/f'{stage}.vvp',root/'inputs/tb_fe_banked_netlist.sv',
                root/'inputs/tb_fe_banked.sv',net,VENDOR/'glbl.v']
            # A separate bounded heavy scope for compile+run; never concurrent
            # with the Vivado family. Timeout reaps descendants on failure.
            native([REPO/'tools/build_scope.sh','--',*compile_command],stage+'-compile',60)
            native([REPO/'tools/build_scope.sh','--','vvp',post/f'{stage}.vvp'],stage+'-scoreboard',180)
            assert 'FE-BANKED-LEAF-OK checks=1300925' in (root/(stage+'-scoreboard.log')).read_text()
        result['passed']=True
    finally:
        result['pins_unchanged']=check_pins(pins)
        result['passed'] &= result['pins_unchanged']
        save(root,'postsim-pins.json',pins)
        save(root,'closed.json',result)
    assert result['passed']
    print('BANKED-PHYSICAL-AND-PRIMITIVE-SCOREBOARD-CLOSED; not full-core qualification',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare-only',action='store_true')
    group.add_argument('--prepared',type=Path)
    args=parser.parse_args()
    if args.prepare_only: prepare()
    else: run(args.prepared)
