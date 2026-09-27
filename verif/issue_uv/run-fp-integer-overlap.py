#!/usr/bin/env python3
"""Architectural differential + required FP/integer overlap (not a QEMU timing oracle)."""
import argparse
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'verif/diff'))
import compare
import tracefmt

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--tb',type=Path,required=True)
    p.add_argument('--branch-only',action='store_true',
                   help='grade direct Jcc/JMP U-branch overlap after long-latency FP')
    args=p.parse_args()
    subprocess.run([ROOT/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    out=Path(tempfile.mkdtemp(prefix='ventium-fp-integer-overlap.'))
    print(f'Artifacts: {out}',flush=True)
    def run(cmd,log,**kwargs):
        with log.open('w') as dest:
            subprocess.run([str(x) for x in cmd],stdout=dest,stderr=subprocess.STDOUT,
                           timeout=180,check=True,**kwargs)
    run(['sha256sum',args.tb.resolve()],out/'binary.sha256')
    failures=[]
    for op,opname in enumerate(('fadd','fmul','fdiv','fsqrt')):
        if args.branch_only and op<2:
            continue
        kinds=list(enumerate(('branch-jmp','branch-jcc-taken','branch-jcc-not-taken'),3)) \
            if args.branch_only else list(enumerate(('pairs','memory','carry')))
        for kind,kindname in kinds:
            timings={}
            for serial in (1,0):
                case=out/f'{opname}-{kindname}-serial{serial}'
                case.mkdir()
                obj,elf,flat=(case/f'test.{ext}' for ext in ('o','elf','flat'))
                run(['as','--32','--defsym',f'FP_OP={op}','--defsym',f'INT_KIND={kind}',
                     '--defsym',f'SERIAL={serial}',ROOT/'verif/issue_uv/t_fp_integer_overlap.s',
                     '-o',obj],case/'as.log')
                run(['ld','-m','elf_i386','-Ttext','0x08048000',obj,'-o',elf],case/'ld.log')
                symbols={v[2]:int(v[0],16) for line in subprocess.check_output(
                    ['nm','-n',str(elf)],text=True).splitlines() if len(v:=line.split())==3}
                run([sys.executable,ROOT/'verif/tests/elf2flat.py',elf,'--out',flat,
                     '--base','0x08048000'],case/'flat.log')
                goldpath=case/'qemu.vtrace'
                run([sys.executable,ROOT/'verif/qemu-trace/gen_trace.py','--qemu',
                     ROOT/'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386',
                     '--elf',elf,'--out',goldpath,'--max-insn',10000,'--port',41957,'--x87'],case/'qemu.log')
                assert 'guest exited, code=0' in (case/'qemu.log').read_text()
                gold=tracefmt.read_trace(str(goldpath))
                traces={}
                for mode in ('cycle','cycle-func'):
                    path=case/f'{mode}.vtrace'
                    run([args.tb.resolve(),'--'+mode,'--x87','--l1-axi','--image',flat,
                         '--load','0x08048000','--entry','0x08048000','--init-esp',gold.records[0]['esp'],
                         '--out',path,'--max-insn',10000,'--max-cycles',2000000,
                         '--quiesce',200000],case/f'{mode}.log',env=dict(os.environ,
                         VEN_FP_OVERLAP_LO=f"{symbols['integer_start']:x}",
                         VEN_FP_OVERLAP_HI=f"{symbols['integer_end']:x}"))
                    tr=tracefmt.read_trace(str(path))
                    assert len(tr.records)==len(gold.records)+1
                    assert int(tr.records[-1]['pc'],0)==symbols['pass_exit']
                    tr.records.pop()
                    assert [r['pc'] for r in tr.records]==[r['pc'] for r in gold.records]
                    traces[mode]=tr
                cyc,state=traces['cycle'],traces['cycle-func']
                ends=[i for i in range(len(cyc.records)) if i+1==len(cyc.records)
                      or cyc.records[i]['cyc']!=cyc.records[i+1]['cyc']]
                with (case/'compare.log').open('w') as log:
                    assert compare.compare_func(tracefmt.Trace(gold.hdr,[gold.records[i] for i in ends]),
                        tracefmt.Trace(state.hdr,[state.records[i] for i in ends]),True,
                        0xffffffff,False,20,log)==0
                starts=[i for i,r in enumerate(cyc.records) if int(r['pc'],0)==symbols['loop_body']]
                assert len(starts)==64
                first,last=starts[8],starts[-1] # exclude cold cache/branch warmup
                if kind==0:
                    paired=sum(bool(r.get('paired',False)) for r in cyc.records[first:last]
                               if symbols['integer_start']<=int(r['pc'],0)<symbols['integer_end'])
                    assert paired>=55, 'register-pair workload did not exercise U/V pairing'
                timings[serial]=(int(cyc.records[last]['cyc'])-int(cyc.records[first]['cyc']),last-first)
                witness=re.findall(r'^\[FP-OVERLAP\] busy_cycles=(\d+) integer_primary=(\d+) '
                                   r'overlapping_primary=(\d+)$',(case/'cycle.log').read_text(),re.M)
                assert len(witness)==1, 'missing/duplicate hardware overlap witness'
                busy,integer,level_overlap=map(int,witness[0])
                aligned=re.findall(r'^\[FP-OVERLAP-COMMIT\] overlapping_primary=(\d+)$',
                                   (case/'cycle.log').read_text(),re.M)
                assert len(aligned)==1, 'missing/duplicate edge-aligned hardware witness; relink testbench'
                overlap=int(aligned[0])
                assert busy>0 and integer>0 and max(overlap,level_overlap)<=integer
                if serial:
                    assert overlap==0, 'FWAIT serial control unexpectedly overlaps'
                elif overlap<55:
                    failures.append(f'{opname}/{kindname}: only {overlap} busy-FPU integer retirements')
                print(f'{opname}/{kindname} serial={serial}: {len(ends)} QEMU groups; '
                      f'{timings[serial][1]} insns / {timings[serial][0]} warm cycles; '
                      f'overlap at commit={overlap}, simultaneous levels={level_overlap}',flush=True)
            assert timings[0][1]==timings[1][1], 'schedules must execute identical instruction counts'
            saved=timings[1][0]-timings[0][0]
            # Require sustained savings, not one boundary/retirement coincidence.
            # Long-latency engines must hide at least four clocks per warm loop;
            # ADD/MUL at least one. These are conservative overlap requirements,
            # not assertions of exact silicon instruction latency.
            required=55 if kind>=3 else 55*(4 if op>=2 else 1)
            if saved<required:
                failures.append(f'{opname}/{kindname}: saved {saved}, require >= {required}')
    for failure in failures: print('OVERLAP-FAIL:',failure)
    if failures:
        print('FP-INTEGER-OVERLAP-FAIL (architectural checks passed; required cycle hiding absent)')
        return 1
    if args.branch_only:
        print('FP-BRANCH-OVERLAP-OK (6 matched-work cases, U-branch busy-FP witness, full x87/integer differential)')
    else:
        print('FP-INTEGER-OVERLAP-OK (12 matched-work cases, full x87/integer differential)')
    return 0

if __name__=='__main__':
    sys.exit(main())
