#!/usr/bin/env python3
"""Build and independently cold-self-check the direct-dispatch microfixtures.

This is fixture preparation only, not a candidate architectural/performance gate.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess

HERE=Path(__file__).resolve().parent
REPO=HERE.parents[1]
def sha(p):
    with Path(p).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--control',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    tb=args.control.resolve(strict=True)
    source=HERE/'system-dispatch.S'
    linker=REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu=REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    pins={str(p):sha(p) for p in (Path(__file__),source,linker,qemu,tb)}
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','QEMU_','AXI_'))}
    env.update(TMPDIR=str(args.out),PYTHONDONTWRITEBYTECODE='1',AXI_RLAT='0',AXI_WLAT='0')
    def run(command,leaf,name,expected=0):
        command=['timeout','--kill-after=3s','30s',*map(str,command)]
        (leaf/(name+'.command.json')).write_text(json.dumps(command,indent=2)+'\n')
        with (leaf/(name+'.stdout')).open('x') as out,(leaf/(name+'.stderr')).open('x') as err:
            code=subprocess.run(command,env=env,stdout=out,stderr=err).returncode
        (leaf/(name+'.exit')).write_text(str(code)+'\n')
        assert code==expected,(name,code,expected)
    def check(case):
        kind,reloc,offset=case
        leaf=args.out/f'control-k{kind}-r{reloc}-o{offset}'; leaf.mkdir()
        result=dict(kind=kind,reloc=reloc,offset=offset,passed=False)
        try:
            obj,elf,image=[leaf/('fixture.'+s) for s in ('o','elf','bin')]
            run(['gcc','-m32','-ffreestanding','-nostdlib','-fno-pic','-fno-pie',
                 f'-DKIND={kind}',f'-DRELOC={reloc}',f'-DOFFSET={offset}','-c',source,'-o',obj],leaf,'assemble')
            run(['gcc','-m32','-static','-no-pie','-nostdlib','-Wl,-T,'+str(linker),
                 '-Wl,--build-id=none',obj,'-o',elf],leaf,'link')
            run(['objcopy','-O','binary','--gap-fill','0','--pad-to','0x100000',elf,image],leaf,'binary')
            assert image.stat().st_size==65536
            run([qemu,'-machine','pc','-cpu','pentium','-m','64','-bios',image,'-display','none',
                 '-serial','none','-monitor','none','-no-reboot','-no-shutdown',
                 '-device','isa-debug-exit,iobase=0xf4,iosize=0x04'],leaf,'qemu',133)
            run([tb,'--system','--cosim','--cycle','--l1-axi','--image',image,
                 '--out',leaf/'cycle.vtrace','--max-insn','2000','--max-cycles','1000000',
                 '--quiesce','4096','+ven_fetchdbg','+ven_fetchdbg_max=10000'],leaf,'native',133)
            result['passed']=True
        except Exception as exc: result['error']=repr(exc)
        return result
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        cases=list(pool.map(check,[(k,r,o) for k in range(4) for r in (0,1) for o in (0,31)]))
    result=dict(passed=all(c['passed'] for c in cases),cases=cases,pins=pins,
                inputs_unchanged=all(sha(p)==h for p,h in pins.items()),
                full_architectural_gate=False,candidate_tested=False,gameplay_ipc=None)
    result['passed'] &= result['inputs_unchanged']
    (args.out/'fixture-closed.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('cases','pins')},indent=2))
    assert result['passed']

if __name__=='__main__': main()
