#!/usr/bin/env python3
"""Full-state differential and fixed-work ALU memory A/B; no gameplay claim."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'verif/diff'))
import compare
import tracefmt


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--control', type=Path, required=True)
    p.add_argument('--candidate', type=Path, required=True)
    p.add_argument('--expect-equal-cycles', action='store_true',
                   help='require cycle identity for a structural refactor instead of an IPC speedup')
    args = p.parse_args()
    subprocess.run([ROOT/'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    out = Path(tempfile.mkdtemp(prefix='ventium-alu-memory-ab.'))
    print(f'Artifacts: {out}', flush=True)
    def run(command, log):
        with log.open('w') as stream:
            subprocess.run([str(x) for x in command], stdout=stream,
                           stderr=subprocess.STDOUT, check=True, timeout=180)
    run(['sha256sum', args.control.resolve(), args.candidate.resolve()], out/'binaries.sha256')
    changes = []
    for op in range(7):
        for carry in range(2):
            case = out/f'op{op}-cf{carry}'
            case.mkdir()
            obj, elf, flat = (case/f'test.{suffix}' for suffix in ('o','elf','flat'))
            run(['as','--32','--defsym',f'OP={op}','--defsym',f'INITIAL_CF={carry}',
                 ROOT/'verif/issue_uv/t_alu_memory_admit.s','-o',obj], case/'as.log')
            run(['ld','-m','elf_i386','-Ttext','0x08048000',obj,'-o',elf], case/'ld.log')
            symbols = {f[2]:int(f[0],16) for line in subprocess.check_output(['nm','-n',elf],text=True).splitlines()
                       if len(f:=line.split())==3}
            run([sys.executable,ROOT/'verif/tests/elf2flat.py',elf,'--out',flat,'--base','0x08048000'],case/'flat.log')
            run([sys.executable,ROOT/'verif/qemu-trace/gen_trace.py','--qemu',
                 ROOT/'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386',
                 '--elf',elf,'--out',case/'qemu.vtrace','--max-insn',20000,'--port',41941],case/'qemu.log')
            assert 'guest exited, code=0' in (case/'qemu.log').read_text()
            gold = tracefmt.read_trace(str(case/'qemu.vtrace'))
            clocks = {}
            for name, binary in [('control',args.control),('candidate',args.candidate)]:
                traces = {}
                for mode in ('cycle','cycle-func'):
                    path = case/f'{name}.{mode}.vtrace'
                    run([binary.resolve(),'--'+mode,'--l1-axi','--image',flat,
                         '--load','0x08048000','--entry','0x08048000',
                         '--init-esp',gold.records[0]['esp'],'--out',path,
                         '--max-insn',20000,'--max-cycles',1000000,'--quiesce',1000],case/f'{name}.{mode}.log')
                    traces[mode] = tracefmt.read_trace(str(path))
                    rows = traces[mode].records
                    assert len(rows)==len(gold.records)+1
                    assert int(rows[-1]['pc'],0)==symbols['exit_syscall']
                    rows.pop()
                    assert [r['pc'] for r in rows]==[r['pc'] for r in gold.records]
                cyc, state = traces['cycle'], traces['cycle-func']
                ends = [i for i in range(len(cyc.records))
                        if i+1==len(cyc.records) or cyc.records[i]['cyc']!=cyc.records[i+1]['cyc']]
                with (case/f'{name}.compare.log').open('w') as log:
                    assert compare.compare_func(tracefmt.Trace(gold.hdr,[gold.records[i] for i in ends]),
                        tracefmt.Trace(state.hdr,[state.records[i] for i in ends]),False,0xffffffff,False,20,log)==0
                starts = [i for i,r in enumerate(cyc.records) if int(r['pc'],0)==symbols['loop_body']]
                assert len(starts)==64
                a,b = starts[8],starts[-1]
                clocks[name] = cyc.records[b]['cyc']-cyc.records[a]['cyc']
                print(f'op={op} CF={carry} {name}: {b-a} instructions / {clocks[name]} cycles; {len(ends)} QEMU groups',flush=True)
            # ADD/ADC are already admitted in the matched control. All other
            # new families must improve; retain every functional comparison.
            changes.append((op,carry,clocks['control'],clocks['candidate']))
    for op,carry,control,candidate in changes:
        if args.expect_equal_cycles:
            assert candidate==control, ('cycle drift',op,carry,control,candidate)
        else:
            assert candidate<=control, ('regression',op,carry,control,candidate)
            if op not in (0,2):
                assert candidate<control, ('no speedup',op,carry,control,candidate)
    print('ALU-MEMORY-AB-OK (14 full-state directed cases; not gameplay acceptance)')


if __name__=='__main__':
    main()
