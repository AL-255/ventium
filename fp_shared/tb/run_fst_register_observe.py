#!/usr/bin/env python3
"""Observe register FST/FSTP source ownership, C1, tags and pop fault behavior.

Directed ISA fixture, not a performance workload or replacement golden. Native
x87 validates the independently constructed architectural expectations; pinned
QEMU is retained as a third observer, including any stack-fault discrepancies.
The optional existing RTL model must run UV-fast and the real AXI backend.
Only ELF-entry setup is captured, before zero guest instructions; no gameplay
snapshot, debugger register write, injected fix or comparator change is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time

ROW_BYTES = 128
INDEFINITE = 0xffffc000000000000000
DEFINED_STATUS = 0xbaff  # B, TOP, C1, ES/SF and exception flags; C0/C2/C3 undefined.


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def cases(all_tops=False):
    return [dict(sti=i,pop=p,source_empty=s,destination_empty=d,masked=m,seed=c,top=t)
            for t in (range(8) if all_tops else (0,))
            for i in range(8) for p in (0,1) for s in (0,1) for d in (0,1)
            for m in (0,1) for c in (0,1) if i != 0 or s == d]


def metadata(c):
    return c['sti'] | c['pop']<<3 | c['source_empty']<<4 | c['destination_empty']<<5 | c['masked']<<6 | c['seed']<<7 | c['top']<<8


def value(n):
    exponent = n.bit_length()-1
    return ((16383+exponent)<<64) | (n<<(63-exponent))


def expected(c):
    top = c['top']
    destination = (top+c['sti']) & 7
    physical = [value(8-((i-top)&7)) for i in range(8)]
    tags = [0]*8
    if c['source_empty']: tags[top] = 3
    if c['destination_empty']: tags[destination] = 3
    sw = 0
    if c['source_empty']:
        sw = 0x0041 if c['masked'] else 0x80c1
    if not c['source_empty'] or c['masked']:
        physical[destination] = INDEFINITE if c['source_empty'] else physical[top]
        tags[destination] = 2 if c['source_empty'] else 0
        if c['pop']:
            tags[top], top = 3, (top+1)&7
    sw |= top<<11
    return dict(fctrl=0x037f if c['masked'] else 0x037e,fstat=sw,
        ftag=sum(t<<(2*i) for i,t in enumerate(tags)),top=top,
        registers=[physical[(i+top)&7] for i in range(8)])


def assembly(items):
    text = ['.section .text','.globl _start','_start:']
    for n,c in enumerate(items):
        offset = n*ROW_BYTES
        text += ['fninit','fldcw cw_masked' if c['masked'] else 'fldcw cw_unmasked']
        text += ['fincstp'] * c['top']
        text += [f'fldt val_{i}' for i in range(1,9)]
        if c['source_empty']: text += ['ffree %st(0)']
        if c['destination_empty'] and c['sti'] != 0: text += [f'ffree %st({c["sti"]})']
        text += ['fnstenv env','andw $0xfdff,env+4']
        if c['seed']: text += ['orw $0x0200,env+4']
        text += ['fldenv env',f'movl ${n},rows+{offset}',f'fnstsw rows+{offset+4}',
            f'movw ${metadata(c)},rows+{offset+6}',
            f'.byte 0xdd,{0xd0+c["sti"]+8*c["pop"]}',
            f'fnsave rows+{offset+8}']
    # Real independent integer pairs ensure the unstepped RTL actually uses V.
    text += ['movl $32,%ecx','uv_loop:','incl %esi','incl %edi','decl %ecx','jnz uv_loop',
        'movl $4,%eax','movl $1,%ebx','movl $rows,%ecx',f'movl ${len(items)*ROW_BYTES},%edx',
        'int $0x80','movl $1,%eax','xorl %ebx,%ebx','int $0x80',
        '.section .data','.balign 4','cw_masked: .word 0x037f','cw_unmasked: .word 0x037e']
    for i in range(1,9):
        v = value(i)
        text += [f'val_{i}: .quad {v&((1<<64)-1)}',f'.word {v>>64}']
    text += ['.section .bss','.balign 16','env: .space 28',f'rows: .space {len(items)*ROW_BYTES}']
    return '\n'.join(text)+'\n'


def decode(data, items):
    assert len(data) == ROW_BYTES*len(items), (len(data),len(items))
    result = []
    for n,c in enumerate(items):
        off = n*ROW_BYTES
        index,before,meta = struct.unpack_from('<IHH',data,off)
        assert index == n and meta == metadata(c)
        assert bool(before&0x200) == bool(c['seed']) and not before&0xff
        assert (before>>11)&7 == c['top']
        ctrl,sw,tag = (struct.unpack_from('<H',data,off+8+field)[0] for field in (0,4,8))
        regs = [int.from_bytes(data[off+36+10*i:off+46+10*i],'little') for i in range(8)]
        result.append(dict(fctrl=ctrl,fstat=sw,ftag=tag,top=(sw>>11)&7,registers=regs,before=before))
    return result


def differences(actual, wanted):
    failures = []
    for key in ('fctrl','ftag','top'):
        if actual[key] != wanted[key]: failures.append(key)
    if (actual['fstat'] ^ wanted['fstat']) & DEFINED_STATUS: failures.append('fstat_defined')
    for i,(got,want) in enumerate(zip(actual['registers'],wanted['registers'],strict=True)):
        physical = (i+wanted['top']) & 7
        # An empty register has no defined numeric value. Its tag/pop state IS checked.
        if (wanted['ftag']>>(2*physical))&3 != 3 and got != want:
            failures.append('st'+str(i))
    return failures


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--model',type=Path)
    ap.add_argument('--model-sha256')
    ap.add_argument('--port',type=int,default=22189)
    ap.add_argument('--all-tops',action='store_true',help='Exercise all eight physical stack rotations')
    args = ap.parse_args()
    assert __debug__ and bool(args.model) == bool(args.model_sha256)
    repo = Path(__file__).resolve().parents[2]
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert out.is_relative_to(scratch) and not out.exists()
    out.mkdir()
    qemu = (repo/'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386').resolve(strict=True)
    generator = repo/'verif/qemu-trace/gen_trace.py'
    pins = {str(p):sha(p) for p in (Path(__file__).resolve(),qemu,generator,repo/'verif/diff/tracefmt.py')}
    if args.model:
        assert sha(args.model) == args.model_sha256
        pins[str(args.model.resolve())] = args.model_sha256
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','TB_','AXI_','QEMU_','VTM_'))}
    env['TMPDIR'] = str(scratch)
    env.update(AXI_RLAT='7', AXI_WLAT='7')
    invocations = []
    def run(name, argv):
        start = time.monotonic()
        p = subprocess.run(list(map(str,argv)),env=env,capture_output=True,timeout=90)
        (out/(name+'.stdout')).write_bytes(p.stdout)
        (out/(name+'.stderr')).write_bytes(p.stderr)
        invocations.append(dict(name=name,argv=list(map(str,argv)),native_exit=p.returncode,seconds=time.monotonic()-start))
        assert p.returncode == 0, (name,p.returncode,p.stderr[-2000:])
        return p.stdout
    items = cases(args.all_tops)
    (out/'cases.json').write_text(json.dumps(items,indent=2)+'\n')
    (out/'probe.S').write_text(assembly(items))
    run('assemble',['as','--32',out/'probe.S','-o',out/'probe.o'])
    run('link',['ld','-m','elf_i386','-Ttext','0x08048000','-o',out/'probe.elf',out/'probe.o'])
    streams = {'native':run('native',[out/'probe.elf']),
               'qemu':run('qemu',[qemu,'-cpu','pentium',out/'probe.elf'])}
    v_retirements = None
    if args.model:
        assert 20000 <= args.port < 32768
        run('entry',[sys.executable,'-B',generator,'--qemu',qemu,'--elf',out/'probe.elf',
            '--syscall-proxy','--image-out',out/'entry.image.json','--out',out/'entry.vtrace',
            '--max-insn','0','--port',str(args.port)])
        assert len((out/'entry.vtrace').read_text().splitlines()) == 1
        run('rtl',[args.model,'--quake-image',out/'entry.image.json','--emulate-syscalls','--x87',
            '--cycle-func','--l1-axi',
            '--max-insn',str(30000*(8 if args.all_tops else 1)),
            '--max-cycles',str(3000000*(8 if args.all_tops else 1)),'--out',out/'rtl.vtrace',
            '--user-stdout',out/'guest.stdout'])
        stderr = (out/'rtl.stderr').read_text()
        assert 'tb: stop: FREE-RUN guest exit_group(0)' in stderr
        assert '[fault-deliveries] actual=0' in stderr
        stdout = (out/'rtl.stdout').read_text()
        match = re.search(r'pairedV=(\d+)',stdout)
        assert match and int(match[1]) > 0
        v_retirements = int(match[1])
        assert re.search(r'backing-ack=[1-9][0-9]*',stdout+stderr), 'AXI backend not observed'
        streams['rtl'] = (out/'guest.stdout').read_bytes()
    decoded = {name:decode(data,items) for name,data in streams.items()}
    findings = []
    for i,c in enumerate(items):
        want = expected(c)
        observed = {name:rows[i] for name,rows in decoded.items()}
        findings.append(dict(index=i,case=c,expected=want,observed=observed,
            differences={name:differences(row,want) for name,row in observed.items()}))
    counts = {name:sum(bool(row['differences'][name]) for row in findings) for name in streams}
    stable = all(sha(p) == h for p,h in pins.items())
    result = dict(kind='FST_REGISTER_OWNERSHIP_DIAGNOSTIC',cases=len(items),mismatch_cases=counts,
        model_sha256=args.model_sha256,v_retirements=v_retirements,pins=pins,invocations=invocations,
        findings=findings,inputs_unchanged=stable,native_is_p54=False,full_instruction_differential=False,
        standard_suite=False,gameplay_ipc=None,
        note='QEMU stack-fault observations retained separately; never a replacement canonical golden.')
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ('findings','pins','invocations')}))
    return int(not stable or counts['native'] != 0 or counts.get('rtl',0) != 0)


if __name__ == '__main__':
    raise SystemExit(main())
