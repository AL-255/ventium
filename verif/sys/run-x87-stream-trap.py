#!/usr/bin/env python3
"""Warm independent FP stream followed by INT3: architectural differential gate."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'verif/diff'))
sys.path.insert(0,str(Path(__file__).resolve().parent))
import tracefmt
from x87_event_compare import compare_complete


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--tb',type=Path,required=True)
    p.add_argument('--fxch-queue',action='store_true')
    p.add_argument('--branch-trap',action='store_true',
                   help='insert a direct branch between pending masked x87 and INT3')
    args=p.parse_args()
    if args.fxch_queue and args.branch_trap:
        p.error('--branch-trap requires the ordinary six-FADD stream')
    subprocess.run([ROOT/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    out=Path(tempfile.mkdtemp(prefix='ventium-x87-stream-trap.'))
    print('Artifacts:',out,flush=True)
    def run(cmd,name,codes=(0,),**kwargs):
        with (out/(name+'.log')).open('w') as log:
            result=subprocess.run(list(map(str,cmd)),stdout=log,stderr=subprocess.STDOUT,
                                  timeout=180,pass_fds=(9,),**kwargs)
        assert result.returncode in codes,(name,result.returncode,out)
    source=ROOT/'verif/sys/tests/px87stk'
    extra=['--defsym','FXCH_QUEUE=1'] if args.fxch_queue else []
    if args.branch_trap:
        extra += ['--defsym','BRANCH_TRAP=1']
    run(['as','--32',*extra,source/'px87streamtrap.S','-o',out/'test.o'],'as')
    run(['ld','-m','elf_i386','-T',source/'px87stk.ld',out/'test.o','-o',out/'test.elf'],'ld')
    run(['objcopy','-O','binary',out/'test.elf',out/'test.bin'],'flat')
    run(['truncate','-s','65536',out/'test.bin'],'pad')
    run([sys.executable,ROOT/'verif/qemu-trace/gen_trace.py','--qemu',
         ROOT/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386',
         '--system','--x87','--image',out/'test.bin','--image-mode','bios','--out',
         out/'qemu.vtrace','--max-insn','5000','--port','41959'],'qemu')
    gold=tracefmt.read_trace(str(out/'qemu.vtrace'))
    assert int(gold.records[-1]['eax'],0)==0x42 and len(gold.records)<5000
    traces={}
    trap_pc=0x800e if args.branch_trap else 0x800c
    for mode in ('cycle','cycle-func'):
        env=None
        if args.branch_trap:
            env=dict(os.environ,VEN_FP_OVERLAP_LO='800c',VEN_FP_OVERLAP_HI='800e')
        run([args.tb.resolve(),'--system','--cosim','--x87','--l1-axi','--'+mode,
             '--image',out/'test.bin','--out',out/(mode+'.vtrace'),'--max-insn','5000',
             '--max-cycles','3000000','--quiesce','200000','+ven_faultlog'],mode,(133,),env=env)
        trace=tracefmt.read_trace(str(out/(mode+'.vtrace')))
        assert [r['pc'] for r in trace.records]==[r['pc'] for r in gold.records],mode
        # INT3 uses software-interrupt entry, not start_fault's diagnostic.
        # The TB's level-based FAULT log also reports reset/IRET transitions;
        # architectural instruction order and the guest handler counter are
        # the authority, not a count of those diagnostic lines.
        assert sum(int(r['pc'],0)==trap_pc for r in trace.records)==64,mode
        traces[mode]=trace
    cyc,state=traces['cycle'],traces['cycle-func']
    ends=[i for i in range(len(cyc.records)) if i+1==len(cyc.records)
          or cyc.records[i]['cyc']!=cyc.records[i+1]['cyc']]
    with (out/'compare.log').open('w') as log:
        assert compare_complete(tracefmt.Trace(gold.hdr,[gold.records[i] for i in ends]),
            tracefmt.Trace(state.hdr,[state.records[i] for i in ends]),log)==0
    # Witness actual consecutive early retirements of the six FP commands,
    # rather than calling a cold/serialized instruction test multi-owner stress.
    bursts=0
    if args.fxch_queue:
        for i,r in enumerate(cyc.records[:-10]):
            block=cyc.records[i:i+11]
            if [int(x['pc'],0) for x in block] == [0x8000,0x8002,*range(0x8004,0x800d)]:
                if int(block[1]['cyc'])-int(block[0]['cyc'])==1:
                    assert int(block[-1]['cyc'])-int(block[0]['cyc'])>=35, 'INT3 did not drain long FP work'
                    bursts+=1
        assert bursts>=8,('no early queued-FXCH trap witness',bursts)
        print(f'X87-FXCH-QUEUE-TRAP-OK: 64 INT3 entries, {bursts} early-FXCH/drain witnesses, QEMU state PASS')
        return
    for i,r in enumerate(cyc.records[:-5]):
        block=cyc.records[i:i+6]
        if [int(x['pc'],0) for x in block]==list(range(0x8000,0x800c,2)):
            if [int(x['cyc'])-int(block[0]['cyc']) for x in block]==list(range(6)):
                bursts+=1
    assert bursts>=8,('no sustained overlapping-FP witness',bursts)
    if args.branch_trap:
        witnesses=re.findall(r'^\[FP-OVERLAP-COMMIT\] overlapping_primary=(\d+)$',
                             (out/'cycle.log').read_text(),re.M)
        assert len(witnesses)==1 and int(witnesses[0])>=55, \
            ('direct branch did not retire with masked FP owners pending',witnesses)
        print(f'X87-BRANCH-TRAP-OK: 64 branch/INT3 entries, {witnesses[0]} busy-FP branch retirements, QEMU state PASS')
        return
    print(f'X87-STREAM-TRAP-OK: 64 INT3 entries, {bursts} consecutive FP bursts, QEMU state PASS')


if __name__=='__main__':
    main()
