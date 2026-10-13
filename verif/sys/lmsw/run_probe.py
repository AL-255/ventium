"""Reproduce missing LMSW on a frozen core; QEMU checks the cold fixture.

This is a self-checking failure witness, NOT repaired RTL or a differential
trace pass. No RTL build, canonical golden/mask change or saved guest state.
"""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[2]


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--model',type=Path,required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    root=args.out.resolve();model=args.model.resolve(strict=True)
    assert __debug__ and root.is_relative_to(scratch) and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve()==scratch and os.sched_getaffinity(0)=={14,15}
    assert os.environ.get('INVOCATION_ID') and shutil.disk_usage(scratch).free>4*1024**3
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    pins={str(p):sha(p) for p in (Path(__file__),HERE/'probe.S',HERE/'probe.ld',qemu,model)}
    assert pins[str(qemu)]=='b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd'
    assert pins[str(model)]=='164e17003b2ec03cd7b92cc8bbe89b576e5f440becc4204e37368e075c87e8df'
    root.mkdir()
    def save(name,obj):
        with (root/name).open('x') as f: json.dump(obj,f,indent=2)
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VENTIUM_','TB_','AXI_','QEMU_'))}
    env.update(AXI_RLAT='7',AXI_WLAT='7',PYTHONDONTWRITEBYTECODE='1')
    def run(name,cmd,seconds=10):
        actual=['taskset','-c','14,15','timeout','--signal=TERM','--kill-after=2s',str(seconds)+'s',*map(str,cmd)]
        save(name+'.command.json',actual)
        with (root/(name+'.log')).open('x') as log:
            return subprocess.run(actual,env=env,stdout=log,stderr=subprocess.STDOUT).returncode
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],affinity=[14,15],
                            diagnostic_only=True,expected_missing=True))
    start=time.monotonic();result=dict(passed=False,rows=[],errors=[],repaired_rtl=False,
        differential_gate=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
    try:
        for mem,op,value,control in itertools.product((0,1),(0,1),(0x11,0xffff),(0,1)):
            name=f'm{mem}-o{op}-v{value:x}-c{control}'
            defines=dict(MEMORY=mem,OP32=op,VALUE=value,CONTROL=control)
            obj,elf,binary=[root/(name+s) for s in ('.o','.elf','.bin')]
            assert run(name+'-as',['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
                *[f'-D{k}={v}' for k,v in defines.items()],'-c',HERE/'probe.S','-o',obj])==0
            assert run(name+'-ld',['ld','-m','elf_i386','-T',HERE/'probe.ld','--build-id=none',obj,'-o',elf])==0
            assert run(name+'-bin',['objcopy','-O','binary',elf,binary])==0
            assert binary.stat().st_size==65536
            q=run(name+'-qemu',[qemu,'-display','none','-monitor','none','-serial','none','-no-reboot',
                '-machine','pc','-cpu','pentium','-m','32','-device','isa-debug-exit,iobase=0xf4,iosize=0x04','-bios',binary],5)
            r=run(name+'-rtl',[model,'--system','--cosim','--cycle-func','--l1-axi','--image',binary,
                '--out',root/(name+'.vtrace'),'--max-insn','2000','--max-cycles','1000000','--quiesce','4096',
                '+ven_faultlog','+ven_seglog'])
            result['rows'].append(dict(case=defines,qemu_exit=q,rtl_exit=r,expected_rtl=133 if control else 135,
                                      image_sha256=sha(binary)))
            assert q==133,(name,'reference fixture failure',q)
            assert r==(133 if control else 135),(name,'missing-instruction witness',r)
            assert 'isa-debug-exit' in (root/(name+'-rtl.log')).read_text()
        result['passed']=True
    except Exception as error:
        result['errors'].append(repr(error))
    result.update(seconds=time.monotonic()-start,pins_unchanged=all(sha(p)==h for p,h in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    print('cases',len(result['rows']),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
