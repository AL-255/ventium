"""Small matched whole-decoder probe; one guarded Vivado family, 10 minute cap."""
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

REPO=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'verif/fe_pipe'))
import prepare_prefix_opcode as recipe
from run_prefix_opcode import PACKAGES

SCRATCH=Path('/home/yukidama/external/tmp').resolve(strict=True)
GIB=1024**3
SCOPE='ventium-vivado.scope'


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def state():
    raw=subprocess.check_output(['systemctl','--user','show',SCOPE,'-p','ActiveState',
        '-p','InvocationID','-p','ControlGroup','-p','MemoryMax','-p','MemorySwapMax'],text=True,timeout=5)
    return dict(line.split('=',1) for line in raw.splitlines() if '=' in line)


def available():
    return next(int(x.split()[1])*1024 for x in Path('/proc/meminfo').read_text().splitlines()
                if x.startswith('MemAvailable:'))


def wrapper(source):
    header=source[:source.index('\n);')]
    ports=re.findall(r'^\s*(input|output)\s+(.+?)\s+(\w+)(\s*\[[^\]]+\])?\s*,?\s*(?://.*)?$',header,re.M)
    assert len(ports)==133
    header=header[header.index('module decode_stages'):].replace('module decode_stages','module decode_probe',1)
    header=header.replace('\n(','\n(\n input logic clk,',1)
    lines=[header,'\n);']
    for direction, kind, name, array in ports:
        lines.append(f'{kind} {"r_" if direction=="input" else "t_"}{name}{array};')
    lines.append('always_ff @(posedge clk) begin')
    for direction, _, name, _ in ports:
        lines.append(f'r_{name} <= {name};' if direction=='input' else f'{name} <= t_{name};')
    lines += ['end','decode_stages dut('+','.join(
        f'.{name}({"r_" if direction=="input" else "t_"}{name})'
        for direction,_,name,_ in ports)+');','endmodule']
    return '\n'.join(lines)+'\n'


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','leaf','manifest','out'): ap.add_argument('--'+name,type=Path,required=True)
    args=ap.parse_args(); root=args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==SCRATCH
    assert root.is_relative_to(SCRATCH) and not root.exists()
    assert SCRATCH.stat().st_dev!=REPO.stat().st_dev
    assert available()>10*GIB and shutil.disk_usage(SCRATCH).free>4*GIB
    assert state().get('ActiveState') in ('inactive','failed')
    assert not any(x.strip().lower() in ('vivado','vrs') for x in subprocess.check_output(
        ['ps','-eo','comm='],text=True).splitlines())
    parent=args.parent.resolve(strict=True); leaf=args.leaf.resolve(strict=True)
    proof=json.loads((leaf/'closed.json').read_text())
    assert proof['passed'] and proof['pins_unchanged'] and proof['checks']==2752512
    assert [r['exit'] for r in proof['native']][:2]==[0,0]
    assert len(proof['native'])==4 and all(r['exit']!=0 for r in proof['native'][2:])
    assert all(sha(p)==h for p,h in proof['pins'].items())
    old=(parent/'candidate'/recipe.FILE).read_text(); new=(leaf/'decode_stages.sv').read_text()
    assert recipe.transform(old)==new
    manifest=args.manifest.resolve(strict=True)
    assert sha(manifest)=='9e53127a928b0044465174583cb7ed87abc8da1d7644056054d3ceeeb5688bbb'
    definitions=json.loads(manifest.read_text())['hardware_defines']; assert len(definitions)==158
    root.mkdir(); inputs=root/'inputs'; inputs.mkdir(); (root/'tmp').mkdir()
    pins=dict(proof['pins'])
    for p in (leaf/'closed.json',Path(__file__),REPO/'fpga/inspect_prefix_opcode.tcl',
              REPO/'fpga/run_vivado_exclusive.sh',REPO/'tools/build_scope.sh',manifest): pins[str(p)]=sha(p)
    def save(path,contents):
        with path.open('x') as f: f.write(contents)
    def generated(name,contents):
        p=inputs/name; save(p,contents); pins[str(p)]=sha(p)
    for p in PACKAGES: generated(Path(p).name,(parent/'candidate'/p).read_text())
    for name,contents in {'parent.sv':old,'fixed.sv':new,'wrapper.sv':wrapper(old),
        'sysop_type.sv':(leaf/'sysop_type.sv').read_text(),
        'definitions.tcl':'set definitions {'+' '.join(definitions)+'}\n',
        'inspect.tcl':(REPO/'fpga/inspect_prefix_opcode.tcl').read_text(),
        'controller.py':Path(__file__).read_text()}.items(): generated(name,contents)
    save(root/'inputs.json',json.dumps(pins,indent=2)+'\n')
    env={k:v for k,v in os.environ.items() if not k.startswith(('VENTIUM_','VEN_','AXI_','TB_'))}
    env.update(TMPDIR=str(root/'tmp'),PYTHONDONTWRITEBYTECODE='1',
        VENTIUM_VIVADO_LOCK_DIR=str(SCRATCH),VENTIUM_VIVADO_MEMORY_MAX='8G',
        VENTIUM_VIVADO_MEMORY_SWAP_MAX='0',VIVADO_BIN='/tools/Xilinx/2025.2/Vivado/bin/vivado')
    script=inputs/'inspect.tcl'
    cmd=['timeout','--signal=TERM','--kill-after=15s','600s',str(REPO/'fpga/run_vivado_exclusive.sh'),
         '-mode','batch','-source',str(script),'-log',str(root/'native.log'),
         '-journal',str(root/'native.jou'),'-tclargs',str(inputs),str(root/'reports')]
    save(root/'command.json',json.dumps(cmd,indent=2)+'\n')
    owner=None; peak=0; events={}; failure=None; start=time.monotonic()
    def stop():
        now=state()
        if owner and now.get('ActiveState')=='active' and now['InvocationID']==owner['InvocationID']:
            subprocess.run(['systemctl','--user','kill','--kill-whom=all','--signal=TERM',SCOPE],timeout=10,check=True)
    with (root/'guard.log').open('x') as log:
        child=subprocess.Popen(cmd,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
        try:
            while child.poll() is None:
                now=state()
                if now.get('ActiveState')=='active':
                    cg=Path('/sys/fs/cgroup'+now['ControlGroup'])
                    if owner is None:
                        for pid in (cg/'cgroup.procs').read_text().split():
                            try: argv=Path('/proc/'+pid+'/cmdline').read_bytes().split(b'\0')
                            except FileNotFoundError: continue
                            if str(script).encode() in argv:
                                assert now['MemoryMax']==str(8*GIB) and now['MemorySwapMax']=='0'
                                owner=now; break
                    if owner:
                        assert owner['InvocationID']==now['InvocationID']
                        try:
                            used=int((cg/'memory.current').read_text())
                            events=dict((k,int(v)) for k,v in (s.split() for s in (cg/'memory.events').read_text().splitlines()))
                        except FileNotFoundError: continue
                        peak=max(peak,used)
                        if used>7*GIB or available()<2*GIB or shutil.disk_usage(root).free<4*GIB or events.get('oom',0):
                            raise RuntimeError('resource reserve')
                time.sleep(.5)
        except BaseException as exc:
            failure=repr(exc); stop()
        finally:
            try: code=child.wait(timeout=630)
            except subprocess.TimeoutExpired:
                stop(); child.terminate(); code=child.wait(timeout=30); failure='native wait timeout'
    closed=dict(native_exit=code,owner=owner,peak_bytes=peak,memory_events=events,
        failure=failure,seconds=time.monotonic()-start,pins_unchanged=all(sha(p)==h for p,h in pins.items()),
        gameplay_ipc=None,core_fmax_qualified=False,standard_suite=False,hardware_acceptance=False)
    save(root/'closed.json',json.dumps(closed,indent=2)+'\n')
    assert code==0 and owner and not failure and closed['pins_unchanged'] and not events.get('oom',0),closed
    assert state().get('ActiveState') in ('inactive','failed')
    report=(root/'reports/receipt.tsv').read_text()
    assert 'COMPLETE CORE_FMAX_QUALIFIED=0' in report
    print(report,flush=True)


if __name__=='__main__': main()
