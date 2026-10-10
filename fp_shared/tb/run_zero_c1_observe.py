#!/usr/bin/env python3
"""P54 zero-C1 ISA matrix: actual native x87, pinned QEMU and UV-fast AXI RTL.

Independent expected state includes full tags/TOP, nonempty values, control,
defined status, exact signed BCD conversion and masked/unmasked stack faults.
Undefined condition codes and empty register payloads are not expectations.
No canonical masks/goldens, guest binaries or debugger registers are altered.
"""
import argparse
import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from run_fst_register_observe import differences, sha, value, ROW_BYTES, INDEFINITE
from run_fld_c1_observe import decode

BCD = ((0,0), (0,1), (1,0), (1,1),
       (999999999999999999,0), (999999999999999999,1), (123456789012345678,0))
UNARY = ((8,0), (8,1), (0,0), (0,1))

def real80(number, sign):
    assert number >= 0 and sign in (0,1)
    return (value(number) if number else 0) | (sign << 79)

def packed_bcd(number, sign):
    assert 0 <= number < 10**18 and sign in (0,1)
    return sum(int(d) << (4*i) for i,d in enumerate(f'{number:018d}'[::-1])) | (sign << 79)

def cases():
    rows=[]
    for top,seed,masked,sticky in itertools.product(range(8),(0,1),(0,1),(0,0x20)):
        base=dict(top=top,seed=seed,masked=masked,sticky=sticky,pc=3,rc=0)
        for data,shape in itertools.product(range(len(BCD)),('normal','overflow')):
            rows.append(dict(base,op='fbld',data=data,shape=shape))
        for op,data,shape in itertools.product(('fabs','fchs'),range(len(UNARY)),('normal','underflow')):
            rows.append(dict(base,op=op,data=data,shape=shape))
        for sti,empty0,emptyi in itertools.product(range(8),(0,1),(0,1)):
            if sti==0 and empty0!=emptyi: continue
            rows.append(dict(base,op='fxch',sti=sti,empty0=empty0,emptyi=emptyi))
    # Orthogonal RC/PC proof: signed zero and both largest-magnitude integers,
    # two TOP positions. FBLD must not round even when PC is only 24/53 bits.
    for pc,rc,top,data in itertools.product((0,2,3),range(4),(0,7),(1,4,5)):
        if (pc,rc)==(3,0): continue
        rows.append(dict(top=top,seed=1,masked=1,sticky=0,pc=pc,rc=rc,
                         op='fbld',data=data,shape='normal'))
    return rows

def control(c):
    return 0x007e | c['masked'] | (c['pc']<<8) | (c['rc']<<10)

def expected(c):
    top=c['top']; physical=[value(8-((i-top)&7)) for i in range(8)]; tags=[0]*8
    fault=False; overflow=False
    if c['op']=='fbld':
        dst=(top-1)&7; overflow=c['shape']=='overflow'; fault=overflow
        if not overflow: tags[dst]=3
        if not fault or c['masked']:
            physical[dst]=INDEFINITE if fault else real80(*BCD[c['data']])
            tags[dst]=2 if fault else (1 if BCD[c['data']][0]==0 else 0)
            top=dst
    elif c['op'] in ('fabs','fchs'):
        number,sign=UNARY[c['data']]; physical[top]=real80(number,sign)
        tags[top]=1 if number==0 else 0
        fault=c['shape']=='underflow'
        if fault: tags[top]=3
        if not fault or c['masked']:
            physical[top]=INDEFINITE if fault else real80(number,0 if c['op']=='fabs' else 1-sign)
            tags[top]=2 if fault else (1 if number==0 else 0)
    else:
        assert c['op']=='fxch'; dst=(top+c['sti'])&7
        if c['empty0']: tags[top]=3
        if c['emptyi']: tags[dst]=3
        fault=bool(c['empty0'] or c['emptyi'])
        if not fault or c['masked']:
            for i in {top,dst}:
                if tags[i]==3: physical[i],tags[i]=INDEFINITE,2
            physical[top],physical[dst]=physical[dst],physical[top]
            tags[top],tags[dst]=tags[dst],tags[top]
    sw=c['sticky'] | (top<<11)
    if fault: sw |= 0x41 | (0x200 if overflow else 0) | (0 if c['masked'] else 0x8080)
    return dict(fctrl=control(c),fstat=sw,ftag=sum(t<<(2*i) for i,t in enumerate(tags)),
                top=top,registers=[physical[(i+top)&7] for i in range(8)])

def assembly(items):
    lines=['.section .text','.globl _start','_start:']
    for n,c in enumerate(items):
        off=n*ROW_BYTES
        lines+=['fninit',f'fldcw cw_{control(c)}']+['fincstp']*c['top']
        for i in range(1,9):
            label=f'unary_{c["data"]}' if i==8 and c['op'] in ('fabs','fchs') else f'val_{i}'
            lines.append('fldt '+label)
        if c['op']=='fbld' and c['shape']=='normal': lines+=['ffree %st(7)']
        if c['op'] in ('fabs','fchs') and c['shape']=='underflow': lines+=['ffree %st(0)']
        if c['op']=='fxch':
            if c['empty0']: lines+=['ffree %st(0)']
            if c['emptyi'] and c['sti']: lines+=[f'ffree %st({c["sti"]})']
        op=(f'fbld bcd_{c["data"]}' if c['op']=='fbld' else
            f'fxch %st({c["sti"]})' if c['op']=='fxch' else c['op'])
        lines+=['fnstenv env','andw $0xfdff,env+4',
                f'orw ${c["seed"]*0x200+c["sticky"]},env+4','fldenv env',
                f'movl ${n},rows+{off}',f'fnstsw rows+{off+4}',op,f'fnsave rows+{off+8}']
    lines+=['movl $32,%ecx','uv_loop:','incl %esi','incl %edi','decl %ecx','jnz uv_loop',
            'movl $4,%eax','movl $1,%ebx','movl $rows,%ecx',f'movl ${len(items)*ROW_BYTES},%edx',
            'int $0x80','movl $1,%eax','xorl %ebx,%ebx','int $0x80','.section .data','.balign 4']
    lines += [f'cw_{cw}: .word {cw}' for cw in sorted({control(c) for c in items})]
    constants={f'val_{i}':value(i) for i in range(1,9)}
    constants.update({f'unary_{i}':real80(*d) for i,d in enumerate(UNARY)})
    constants.update({f'bcd_{i}':packed_bcd(*d) for i,d in enumerate(BCD)})
    for label,v in constants.items(): lines+=[f'{label}: .quad {v&((1<<64)-1)}',f'.word {v>>64}']
    lines+=['.section .bss','.balign 16','env: .space 28',f'rows: .space {len(items)*ROW_BYTES}']
    return '\n'.join(lines)+'\n'

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--model',type=Path,required=True)
    ap.add_argument('--model-sha256',required=True)
    ap.add_argument('--port',type=int,default=25479)
    args=ap.parse_args();repo=Path(__file__).resolve().parents[2]
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    out=args.out.resolve();assert out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve().is_relative_to(scratch)
    assert sha(args.model)==args.model_sha256
    qemu=repo/'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386'
    gen=repo/'verif/qemu-trace/gen_trace.py'
    paths=[Path(__file__),Path(__file__).with_name('run_fst_register_observe.py'),
           Path(__file__).with_name('run_fld_c1_observe.py'),args.model.resolve(),
           qemu,gen,repo/'verif/diff/tracefmt.py']
    pins={str(p):sha(p) for p in paths};out.mkdir();calls=[]
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_'))}
    env.update(TMPDIR=str(out),AXI_RLAT='7',AXI_WLAT='7')
    def run(name,argv):
        argv=list(map(str,argv));start=time.monotonic()
        p=subprocess.run(argv,env=env,capture_output=True,timeout=240)
        (out/(name+'.stdout')).write_bytes(p.stdout);(out/(name+'.stderr')).write_bytes(p.stderr)
        calls.append(dict(name=name,command=argv,native_exit=p.returncode,seconds=time.monotonic()-start))
        assert p.returncode==0,(name,p.returncode,p.stderr[-2000:])
        return p.stdout
    items=cases();(out/'probe.S').write_text(assembly(items))
    run('assemble',['as','--32',out/'probe.S','-o',out/'probe.o'])
    run('link',['ld','-m','elf_i386','-Ttext','0x08048000','-o',out/'probe.elf',out/'probe.o'])
    streams={'native':run('native',[out/'probe.elf']),
             'qemu':run('qemu',[qemu,'-cpu','pentium',out/'probe.elf'])}
    run('entry',[sys.executable,'-B',gen,'--qemu',qemu,'--elf',out/'probe.elf','--syscall-proxy',
                 '--image-out',out/'entry.image.json','--out',out/'entry.vtrace',
                 '--max-insn','0','--port',args.port])
    assert len((out/'entry.vtrace').read_text().splitlines())==1
    run('rtl',[args.model,'--quake-image',out/'entry.image.json','--emulate-syscalls','--x87',
        '--cycle-func','--l1-axi','--max-insn','400000','--max-cycles','20000000',
        '--out',out/'rtl.vtrace','--user-stdout',out/'guest.stdout'])
    stdout=(out/'rtl.stdout').read_text();stderr=(out/'rtl.stderr').read_text()
    assert 'tb: stop: FREE-RUN guest exit_group(0)' in stderr and '[fault-deliveries] actual=0' in stderr
    v=re.search(r'pairedV=(\d+)',stdout);assert v and int(v[1])>0
    assert re.search(r'backing-ack=[1-9][0-9]*',stdout+stderr)
    streams['rtl']=(out/'guest.stdout').read_bytes()
    rows={name:decode(data,items) for name,data in streams.items()}
    findings=[dict(case=c,expected=expected(c),observed={k:v[n] for k,v in rows.items()},
        differences={k:differences(v[n],expected(c)) for k,v in rows.items()}) for n,c in enumerate(items)]
    counts={name:sum(bool(r['differences'][name]) for r in findings) for name in streams}
    assert all(sha(p)==h for p,h in pins.items())
    result=dict(cases=len(items),mismatches=counts,findings=findings,pins=pins,calls=calls,
        model=args.model_sha256,v_retirements=int(v[1]),inputs_unchanged=True,
        canonical_gate=False,standard_suite=False,gameplay_ipc=None,native_host_is_p54=False)
    (out/'result.json').write_text(json.dumps(result,indent=2))
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','findings','calls')}))
    return int(bool(counts['native'] or counts['rtl']))

if __name__=='__main__':raise SystemExit(main())
