"""Cold UV-fast reproduction of the small-nearest-quotient RTL defect."""
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

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]
sys.path.insert(0,str(REPO/'verif/diff'))
import tracefmt


def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()


def save(path,value):
    with path.open('x') as f:json.dump(value,f,indent=2)


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--core',type=Path)
    ap.add_argument('--program',type=Path,default=HERE/'small_quotient.S')
    args=ap.parse_args();root=args.out.resolve();scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    program=args.program.resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.sched_getaffinity(0)=={13}
    assert os.environ['INVOCATION_ID'] and shutil.disk_usage(scratch).free>4*1024**3+16*1024**2
    core=args.core.resolve(strict=True) if args.core else scratch/'ventium-data-size.v2HaTO2X/backing-payload-mux-core-r1'
    model=core/'obj/tb_ventium'
    built=json.loads((core/'build-closed.json').read_text())
    started=json.loads((core/'build-started.json').read_text())
    assert built['passed'] and built['pins_unchanged'] and built['native_exit']==0
    assert sha(model)==built['binary_sha256']
    if not args.core:assert sha(model)=='7c88579767354f269055420cafe3acca089acda87e5ac174b633b3e7905dcdb5'
    definitions=set(re.findall(r'\+define\+(\w+)',(core/'obj/Vventium_top__verFiles.dat').read_text()))
    assert {'VEN_L1_AXI','VEN_FE_PIPE','VEN_SYS_FASTPATH','VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT','VEN_SYS_FASTSTORE_FLAT'}<=definitions
    qemu=scratch/'ventium-qemu-frndint.wRXifJwr/build-r1/build/qemu-i386'
    assert sha(qemu)=='da49b8105f90b4257494a7b7f1e57e5428fa66dc667278b824d381d9d0e9f84d'
    producer=REPO/'verif/qemu-trace/gen_trace.py';comparator=REPO/'verif/diff/compare.py'
    flatten=REPO/'verif/tests/elf2flat.py'
    pins=dict(started['pins'])
    pins.update({str(p):sha(p) for p in (Path(__file__),program,qemu,model,
        core/'build-started.json',core/'build-closed.json',producer,comparator,flatten,REPO/'verif/diff/tracefmt.py')})
    assert all(sha(p)==h for p,h in pins.items())
    root.mkdir();save(root/'started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        cold=True,no_trace_masks=True,cycle_mode=1,l1_axi=True,axi_latency=7))
    rows=[];begin=time.monotonic()
    def run(label,command,env=None):
        with (root/(label+'.log')).open('x') as f:
            child=subprocess.Popen(list(map(str,command)),env=env,stdout=f,stderr=subprocess.STDOUT)
            observed=set();start=time.monotonic()
            try:
                while child.poll() is None:
                    try:observed.add(tuple(sorted(os.sched_getaffinity(child.pid))))
                    except ProcessLookupError:pass
                    assert time.monotonic()-start<60,label+' timeout'
                    time.sleep(.0001)
                code=child.wait()
            finally:
                if child.poll() is None:child.kill()
                child.wait()
        assert observed=={(13,)}
        rows.append(dict(label=label,command=list(map(str,command)),native_exit=code,
            observed_affinity=sorted(observed),actual_wait=True,reaped=True))
        return code
    assert run('compile',['gcc','-m32','-march=pentium','-nostdlib','-static','-Wl,--build-id=none',
        '-Wl,-Ttext=0x08048000','-o',root/'test.elf',program])==0
    assert run('flatten',[sys.executable,'-B',flatten,root/'test.elf','--out',root/'test.flat','--base','0x08048000'])==0
    native_selfcheck=run('native',[root/'test.elf'])
    qemu_selfcheck=run('guest',[qemu,'-cpu','pentium',root/'test.elf'])
    # Retain a failing reference self-check, but still collect the RTL trace.
    # Agreement between two failing implementations must never count as pass.
    assert native_selfcheck==0
    assert run('trace',[sys.executable,'-B',producer,'--qemu',qemu,'--elf',root/'test.elf',
        '--out',root/'qemu.vtrace','--max-insn','128','--port','42501','--x87'],
        dict(os.environ,VTM_QEMU_GDB_PREEXIT='1',TMPDIR=str(root)))==0
    qt=tracefmt.read_trace(str(root/'qemu.vtrace')).records
    assert qt[0]['pc']=='0x08048000' and qt[0]['bytes'].startswith('31ed')
    fields=dict(line.split('=',1) for line in (root/'flatten.log').read_text().splitlines())
    rtl=run('rtl',[model,'--image',root/'test.flat','--load',fields['load_addr'],'--entry',fields['entry'],
        '--init-esp',qt[0]['esp'],'--out',root/'rtl.vtrace','--max-insn','128','--max-cycles','100000',
        '--x87','--cycle-func','--l1-axi'],dict(os.environ,AXI_RLAT='7',AXI_WLAT='7'))
    diff=run('compare',[sys.executable,'-B',comparator,'--mode','func',root/'qemu.vtrace',root/'rtl.vtrace'])
    rt=tracefmt.read_trace(str(root/'rtl.vtrace')).records;log=(root/'rtl.log').read_text()
    paired=int(re.search(r'pairedV=(\d+)',log).group(1))
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(passed=stable and native_selfcheck==qemu_selfcheck==rtl==diff==0
        and int(rt[-1]['ebx'],16)==0 and int(rt[-1]['ebp'],16)==1 and paired>0,
        pins_unchanged=stable,rows=rows,qemu_records=len(qt),rtl_records=len(rt),
        native_selfcheck_exit=native_selfcheck,qemu_selfcheck_exit=qemu_selfcheck,
        qemu_guest_exit=int(qt[-1]['ebx'],16),rtl_guest_exit=int(rt[-1]['ebx'],16),
        actual_v_retirements=paired,axi_backend='--l1-axi selected' in log,
        seconds=time.monotonic()-begin,canonical_gate_passed=False,standard_suite=False,
        hardware_acceptance=False,gameplay_ipc=None)
    save(root/'closed.json',result);print(json.dumps(result,indent=2),flush=True)
    return int(not result['passed'])


if __name__=='__main__':raise SystemExit(main())
