#!/usr/bin/env python3
"""Independent finite FST narrowing/value/status witness; not a canonical golden.

Real ISA seeds C1 then stores to sentinel memory and saves x87 state. No
debugger writes, post-execution state replacement or trace masks are used.
"""
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import time

ROW=128


def power(exponent):
    return Fraction(1<<exponent) if exponent>=0 else Fraction(1,1<<-exponent)


def cases():
    result=[]
    for bits,p,emin,emax in ((32,24,-126,127),(64,53,-1022,1023)):
        low=64-p
        mantissas=[1<<63,(1<<63)+1,(1<<63)+(1<<(low-1)),
                  (1<<63)+(1<<(low-1))+1,(1<<63)+(3<<(low-1)),(1<<64)-1]
        for exponent in (0,emin-2,emin-1,emin,emax,emax+1):
            for mantissa in mantissas:
                for sign in (0,1):
                    for rc in range(4):
                        for pop in (0,1):
                            for seed in (0,1):
                                result.append(dict(bits=bits,exponent=exponent,mantissa=mantissa,
                                                   sign=sign,rc=rc,pop=pop,seed=seed))
    for exponent in (0,-1100,1100):
        for sign in (0,1):
            for rc in range(4):
                for seed in (0,1):
                    result.append(dict(bits=80,exponent=exponent,mantissa=(1<<63)+1,
                                       sign=sign,rc=rc,pop=1,seed=seed))
    return result


def input80(c):
    return c['sign']<<79 | (16383+c['exponent'])<<64 | c['mantissa']


def expected(c):
    bits=c['bits']; sign=c['sign']; rc=c['rc']
    if bits==80: return dict(value=input80(c),flags=0,c1=0)
    p,emin,emax,ebits=(24,-126,127,8) if bits==32 else (53,-1022,1023,11)
    magnitude=Fraction(c['mantissa'])*power(c['exponent']-63)
    exponent=max(emin,c['exponent'])
    scaled=magnitude/power(exponent-(p-1))
    kept,remainder=divmod(scaled.numerator,scaled.denominator)
    inexact=bool(remainder)
    increment=(2*remainder>scaled.denominator or
               (2*remainder==scaled.denominator and bool(kept&1))) if rc==0 else (
               inexact and ((rc==1 and bool(sign)) or (rc==2 and not sign)))
    kept+=int(increment)
    if kept>=1<<p: kept>>=1; exponent+=1
    if exponent>emax:
        infinity=(rc==0 or (rc==1 and bool(sign)) or (rc==2 and not sign))
        magbits=(((1<<ebits)-1)<<(p-1)) if infinity else (((1<<ebits)-2)<<(p-1)) | ((1<<(p-1))-1)
        return dict(value=sign<<(bits-1)|magbits,flags=0x28,c1=int(infinity))
    normal=kept>=1<<(p-1)
    exponent_bits=exponent+emax if normal else 0
    value=sign<<(bits-1)|exponent_bits<<(p-1)|(kept&((1<<(p-1))-1))
    return dict(value=value,flags=(0x20 if inexact else 0)|(0x10 if inexact and not normal else 0),
                c1=int(increment))


def assembly(items):
    text=['.section .text','.globl _start','_start:']
    for i,c in enumerate(items):
        row=i*ROW
        op=({32:'fstps',64:'fstpl',80:'fstpt'} if c['pop'] else {32:'fsts',64:'fstl'})[c['bits']]
        text+=['fninit',f'fldcw cw_{c["rc"]}',f'fldt value_{i}','fnstenv env',
               'andw $0xfdff,env+4']
        if c['seed']: text+=['orw $0x0200,env+4']
        text+=['fldenv env',f'fnstsw rows+{row}',f'{op} rows+{row+4}',f'fnsave rows+{row+20}']
    text+=['movl $32,%ecx','uv_loop:','incl %esi','incl %edi','decl %ecx','jnz uv_loop',
           'movl $4,%eax','movl $1,%ebx','movl $rows,%ecx',f'movl ${len(items)*ROW},%edx',
           'int $0x80','movl $1,%eax','xorl %ebx,%ebx','int $0x80','.section .data','.balign 4']
    for rc in range(4): text+=[f'cw_{rc}: .word {0x37f | rc<<10}']
    for i,c in enumerate(items):
        v=input80(c);text+=[f'value_{i}: .quad {v&((1<<64)-1)}',f'.word {v>>64}']
    text+=['.balign 16',f'rows: .fill {len(items)*ROW},1,0xa5',
           '.section .bss','.balign 16','env: .space 28']
    return '\n'.join(text)+'\n'


def decode(data,items):
    if len(data)!=ROW*len(items): raise ValueError('wrong output length')
    rows=[]
    for i,c in enumerate(items):
        at=i*ROW; n=c['bits']//8
        before=struct.unpack_from('<H',data,at)[0]
        cw,sw,tw=(
            struct.unpack_from('<H',data,at+20)[0],struct.unpack_from('<H',data,at+24)[0],
            struct.unpack_from('<H',data,at+28)[0])
        if bool(before&0x200)!=bool(c['seed']): raise ValueError('C1 seed not loaded')
        if data[at+4+n:at+20]!=b'\xa5'*(16-n): raise ValueError('store exceeded its width')
        rows.append(dict(value=int.from_bytes(data[at+4:at+4+n],'little'),
                         sw=sw,cw=cw,tw=tw,c1=(sw>>9)&1,flags=sw&0x3f,
                         st0=int.from_bytes(data[at+48:at+58],'little')))
    return rows


def differences(row,c,want):
    bad=[key for key in ('value','flags','c1') if row[key]!=want[key]]
    if row['cw']!=(0x37f|c['rc']<<10): bad.append('cw')
    if (row['sw']>>11)&7 != (0 if c['pop'] else 7): bad.append('top')
    if row['sw']&0x80c0: bad.append('unexpected_exception_summary')
    if row['tw']!=(0xffff if c['pop'] else 0x3fff): bad.append('tag')
    if not c['pop'] and row['st0']!=input80(c): bad.append('st0')
    return bad


def sha(path):
    with Path(path).open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--model',type=Path,required=True)
    ap.add_argument('--model-sha256',required=True)
    a=ap.parse_args(); assert __debug__
    repo=Path(__file__).resolve().parents[2]; scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    out=a.out.resolve(); assert out.is_relative_to(scratch) and not out.exists();out.mkdir()
    qemu=(repo/'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386').resolve(strict=True)
    generator=repo/'verif/qemu-trace/gen_trace.py'
    pins={str(p):sha(p) for p in (Path(__file__).resolve(),qemu,generator,repo/'verif/diff/tracefmt.py',a.model.resolve())}
    assert sha(a.model)==a.model_sha256
    env={k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_','VTM_'))}
    env.update(TMPDIR=str(scratch),AXI_RLAT='7',AXI_WLAT='7')
    calls=[]
    def run(name,argv):
        start=time.monotonic();p=subprocess.run(list(map(str,argv)),env=env,capture_output=True,timeout=180)
        (out/(name+'.stdout')).write_bytes(p.stdout);(out/(name+'.stderr')).write_bytes(p.stderr)
        calls.append(dict(name=name,argv=list(map(str,argv)),native_exit=p.returncode,seconds=time.monotonic()-start))
        assert p.returncode==0,(name,p.returncode,p.stderr[-1000:]);return p.stdout
    items=cases(); (out/'cases.json').write_text(json.dumps(items,indent=2))
    (out/'probe.S').write_text(assembly(items))
    run('assemble',['as','--32',out/'probe.S','-o',out/'probe.o'])
    run('link',['ld','-m','elf_i386','-Ttext','0x08048000','-o',out/'probe.elf',out/'probe.o'])
    streams={'native':run('native',[out/'probe.elf']), 'qemu':run('qemu',[qemu,'-cpu','pentium',out/'probe.elf'])}
    with socket.socket() as sock: sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    run('entry',[sys.executable,'-B',generator,'--qemu',qemu,'--elf',out/'probe.elf','--syscall-proxy',
                 '--image-out',out/'entry.image.json','--out',out/'entry.vtrace','--max-insn','0','--port',str(port)])
    assert len((out/'entry.vtrace').read_text().splitlines())==1
    run('rtl',[a.model,'--quake-image',out/'entry.image.json','--emulate-syscalls','--x87','--cycle-func',
        '--l1-axi','--max-insn','200000','--max-cycles','12000000','--out',out/'rtl.vtrace',
        '--user-stdout',out/'guest.stdout'])
    stderr=(out/'rtl.stderr').read_text();stdout=(out/'rtl.stdout').read_text()
    assert 'tb: stop: FREE-RUN guest exit_group(0)' in stderr
    assert '[fault-deliveries] actual=0' in stderr
    paired=re.search(r'pairedV=(\d+)',stdout);assert paired and int(paired[1])>0
    assert re.search(r'backing-ack=[1-9][0-9]*',stdout+stderr)
    streams['rtl']=(out/'guest.stdout').read_bytes()
    decoded={name:decode(data,items) for name,data in streams.items()}
    findings=[]
    for i,c in enumerate(items):
        want=expected(c);observed={name:rows[i] for name,rows in decoded.items()}
        findings.append(dict(case=c,expected=want,observed=observed,
            differences={name:differences(row,c,want) for name,row in observed.items()}))
    counts={name:sum(bool(row['differences'][name]) for row in findings) for name in streams}
    stable=all(sha(p)==h for p,h in pins.items())
    result=dict(kind='FST_MEMORY_FINITE_DIAGNOSTIC',cases=len(items),model=a.model_sha256,mismatch_cases=counts,
        findings=findings,pins=pins,inputs_unchanged=stable,invocations=calls,v_retirements=int(paired[1]),
        native_is_p54=False,full_instruction_differential=False,standard_suite=False,gameplay_ipc=None)
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('findings','pins','invocations')}))
    return int(not stable or counts['native']!=0 or counts['rtl']!=0)


if __name__=='__main__': raise SystemExit(main())
