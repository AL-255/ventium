#!/usr/bin/env python3
"""Directed FLD/FILD/constant-load C1 and stack-fault ISA regression.

Actual native x87, pinned QEMU and UV-fast AXI RTL execute the same ELF.
No debugger state changes, guest repair hooks or canonical comparison masks.
Only C0/C2/C3, architecturally undefined for these loads, are excluded from
this independent expected-state check. The canonical comparator is untouched.
"""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time

from run_fst_register_observe import value, differences, sha, ROW_BYTES, INDEFINITE

OPS = ('flds m32', 'fldl m64', 'fldt m80', 'fld %st(0)',
       'filds i16', 'fildl i32', 'fildq i64', 'fld1', 'fldz')

def cases():
    return [dict(op=op, top=t, seed=s, masked=m, shape=h, sticky=p)
            for op in OPS for t in range(8) for s in (0,1) for m in (0,1)
            for h in (('normal','overflow','underflow') if op=='fld %st(0)'
                      else ('normal','overflow')) for p in (0,0x20)]

def expected(c):
    top=c['top']; dest=(top-1)&7
    physical=[value(8-((i-top)&7)) for i in range(8)]
    tags=[0]*8
    if c['shape']!='overflow': tags[dest]=3
    if c['shape']=='underflow': tags[top]=3
    fault=c['shape']!='normal'
    status=c['sticky'] | (0x41 if fault else 0)
    if fault and not c['masked']: status|=0x8080
    if c['shape']=='overflow': status|=0x200
    if not fault or c['masked']:
        physical[dest]=(INDEFINITE if fault else
                        value(8) if c['op']=='fld %st(0)' else
                        0 if c['op']=='fldz' else value(1))
        tags[dest]=2 if fault else 1 if c['op']=='fldz' else 0
        top=dest
    return dict(fctrl=0x37f if c['masked'] else 0x37e, fstat=status|(top<<11),
        ftag=sum(t<<(2*i) for i,t in enumerate(tags)),top=top,
        registers=[physical[(i+top)&7] for i in range(8)])

def assembly(items):
    lines=['.section .text','.globl _start','_start:']
    for n,c in enumerate(items):
        offset=n*ROW_BYTES
        lines+=['fninit','fldcw cw_masked' if c['masked'] else 'fldcw cw_unmasked']
        lines+=['fincstp']*c['top']
        lines+=[f'fldt val_{i}' for i in range(1,9)]
        if c['shape']!='overflow': lines+=['ffree %st(7)']
        if c['shape']=='underflow': lines+=['ffree %st(0)']
        lines+=['fnstenv env','andw $0xfdff,env+4',
                f'orw ${c["seed"]*0x200+c["sticky"]},env+4','fldenv env',
                f'movl ${n},rows+{offset}',f'fnstsw rows+{offset+4}',
                c['op'],f'fnsave rows+{offset+8}']
    lines+=['movl $32,%ecx','uv_loop:','incl %esi','incl %edi','decl %ecx','jnz uv_loop',
        'movl $4,%eax','movl $1,%ebx','movl $rows,%ecx',f'movl ${len(items)*ROW_BYTES},%edx',
        'int $0x80','movl $1,%eax','xorl %ebx,%ebx','int $0x80','.section .data','.balign 4',
        'cw_masked: .word 0x037f','cw_unmasked: .word 0x037e',
        'm32: .long 0x3f800000','m64: .quad 0x3ff0000000000000',
        'm80: .quad 0x8000000000000000','.word 0x3fff',
        'i16: .word 1','i32: .long 1','i64: .quad 1']
    for i in range(1,9):
        v=value(i);lines+=[f'val_{i}: .quad {v&((1<<64)-1)}',f'.word {v>>64}']
    lines+=['.section .bss','.balign 16','env: .space 28',f'rows: .space {len(items)*ROW_BYTES}']
    return '\n'.join(lines)+'\n'

def decode(data,items):
    assert len(data)==ROW_BYTES*len(items),(len(data),len(items))
    rows=[]
    for n,c in enumerate(items):
        offset=n*ROW_BYTES
        index,before=struct.unpack_from('<IH',data,offset)
        assert index==n and (before&0x200)==c['seed']*0x200
        assert (before&0xff)==c['sticky'] and (before>>11)&7==c['top']
        cw,sw,tag=(struct.unpack_from('<H',data,offset+8+i)[0] for i in (0,4,8))
        rows.append(dict(fctrl=cw,fstat=sw,ftag=tag,top=(sw>>11)&7,
            registers=[int.from_bytes(data[offset+36+10*i:offset+46+10*i],'little') for i in range(8)]))
    return rows

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--model',type=Path,required=True)
    ap.add_argument('--model-sha256',required=True)
    args=ap.parse_args()
    repo=Path(__file__).resolve().parents[2]
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    out=args.out.resolve();assert out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch)
    assert sha(args.model)==args.model_sha256
    qemu=repo/'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386'
    gen=repo/'verif/qemu-trace/gen_trace.py'
    paths=[Path(__file__),Path(__file__).with_name('run_fst_register_observe.py'),
           args.model.resolve(),qemu,gen,repo/'verif/diff/tracefmt.py']
    pins={str(p):sha(p) for p in paths};out.mkdir()
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(out),AXI_RLAT='7',AXI_WLAT='7')
    calls=[]
    def run(name,argv):
        command=list(map(str,argv));start=time.monotonic()
        proc=subprocess.run(command,env=env,capture_output=True,timeout=180)
        (out/(name+'.stdout')).write_bytes(proc.stdout)
        (out/(name+'.stderr')).write_bytes(proc.stderr)
        calls.append(dict(name=name,command=command,native_exit=proc.returncode,seconds=time.monotonic()-start))
        assert proc.returncode==0,(name,proc.returncode,proc.stderr[-2000:])
        return proc.stdout
    items=cases();(out/'probe.S').write_text(assembly(items))
    run('assemble',['as','--32',out/'probe.S','-o',out/'probe.o'])
    run('link',['ld','-m','elf_i386','-Ttext','0x08048000','-o',out/'probe.elf',out/'probe.o'])
    streams={'native':run('native',[out/'probe.elf']),
             'qemu':run('qemu',[qemu,'-cpu','pentium',out/'probe.elf'])}
    run('entry',[sys.executable,'-B',gen,'--qemu',qemu,'--elf',out/'probe.elf',
        '--syscall-proxy','--image-out',out/'entry.image.json','--out',out/'entry.vtrace',
        '--max-insn','0','--port','25179'])
    assert len((out/'entry.vtrace').read_text().splitlines())==1
    run('rtl',[args.model,'--quake-image',out/'entry.image.json','--emulate-syscalls','--x87',
        '--cycle-func','--l1-axi','--max-insn','200000','--max-cycles','20000000',
        '--out',out/'rtl.vtrace','--user-stdout',out/'guest.stdout'])
    stdout=(out/'rtl.stdout').read_text();stderr=(out/'rtl.stderr').read_text()
    assert 'tb: stop: FREE-RUN guest exit_group(0)' in stderr
    assert '[fault-deliveries] actual=0' in stderr
    match=re.search(r'pairedV=(\d+)',stdout);assert match and int(match[1])>0
    assert re.search(r'backing-ack=[1-9][0-9]*',stdout+stderr)
    streams['rtl']=(out/'guest.stdout').read_bytes()
    rows={name:decode(data,items) for name,data in streams.items()}
    findings=[dict(case=c,expected=expected(c),observed={k:v[n] for k,v in rows.items()},
        differences={k:differences(v[n],expected(c)) for k,v in rows.items()}) for n,c in enumerate(items)]
    counts={name:sum(bool(r['differences'][name]) for r in findings) for name in streams}
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(cases=len(items),mismatches=counts,findings=findings,pins=pins,calls=calls,
        model=args.model_sha256,v_retirements=int(match[1]),inputs_unchanged=True,
        canonical_gate=False,standard_suite=False,gameplay_ipc=None,native_host_is_p54=False)
    (out/'result.json').write_text(json.dumps(result,indent=2))
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','findings','calls')}))
    return int(bool(counts['native'] or counts['rtl']))

if __name__=='__main__':raise SystemExit(main())
