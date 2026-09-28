#!/usr/bin/env python3
"""Nonidentity split-source ALU fault/retry, independent QEMU and RTL checks."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'verif/diff'))
import compare
import tracefmt


def validate_source_events(log):
    faults = re.findall(r'^\[FAULT\].*$', log, re.M)
    assert len(faults)==1 and re.match(
        r'\[FAULT\] vec=14 err=00000000 pc=00008013\b', faults[0]), 'wrong fault count or identity'
    commits = re.findall(r'\[PIPE-RETIRE\] pc=00008013 explicit=(\d)',log)
    # System traces include the failed single-step's exception snapshot at
    # the source PC, followed by its successful retry. The first is not an
    # architectural instruction completion. Do not compare textual positions
    # across FAULT (stdout) and PIPE-RETIRE (stderr): buffering can reorder them.
    assert len(commits)==2 and commits[0]=='0', 'wrong fault snapshot/retry metadata'
    # The fixture uses protected, paged system mode. The current fast decoder
    # cannot represent every CS.D=0 instruction, so fp_sys_bail must keep this
    # access on the common slow/fragment path even with VEN_FAST_MEM_ALU set.
    # This is a fault/retry and system-mode exclusion test, not evidence that
    # the memory-ALU fast path can handle a paged fault itself.
    owners = re.findall(r'^\[MEMOWNER\] cyc=\d+ state=\d+ active=1 '
                        r'pc=00008013 ea=00404fff write=0$', log, re.M)
    assert not owners, 'system-mode faulting read entered the fast memory path'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--control', type=Path, required=True)
    p.add_argument('--candidate', type=Path, required=True)
    p.add_argument('--fp-overlap', action='store_true',
                   help='precede the split-page access with normal-operand FDIV; compare x87 too')
    p.add_argument('--memory-chain', action='store_true',
                   help='precede faulting source with an independently owned warm integer load')
    args = p.parse_args()
    if args.fp_overlap and args.memory_chain:
        p.error('--fp-overlap and --memory-chain are separate predecessor fixtures')
    subprocess.run([ROOT/'tools/build_scope.sh','--is-active'],pass_fds=(9,),check=True)
    out = Path(tempfile.mkdtemp(prefix='ventium-alu-memory-fault.'))
    print(f'Artifacts: {out}',flush=True)
    def run(command,log,**kwargs):
        with log.open('w') as stream:
            subprocess.run([str(x) for x in command],stdout=stream,stderr=subprocess.STDOUT,
                           check=True,timeout=180,**kwargs)
    qemu = ROOT/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    run(['sha256sum',qemu,args.control.resolve(),args.candidate.resolve()],out/'binaries.sha256')
    for op in range(7):
        for carry in range(2):
            case = out/f'op{op}-cf{carry}'
            case.mkdir()
            obj,elf,image = (case/f'test.{suffix}' for suffix in ('o','elf','bin'))
            run(['as','--32','--defsym',f'ALU_OP={op}','--defsym',f'INITIAL_CF={carry}',
                 *(['--defsym','FP_OVERLAP=1'] if args.fp_overlap else []),
                 *(['--defsym','MEMORY_CHAIN=1'] if args.memory_chain else []),
                 ROOT/'verif/issue_uv/t_alu_memory_fault.S','-o',obj],case/'as.log',
                cwd=ROOT/'verif/sys/tests/pbytemovpg')
            run(['ld','-m','elf_i386','-T',ROOT/'verif/sys/tests/ppage/ppage.ld',obj,'-o',elf],case/'ld.log')
            run(['objcopy','-O','binary',elf,image],case/'objcopy.log')
            run(['truncate','-s','65536',image],case/'pad.log')
            with (case/'free-qemu.log').open('w') as log:
                free = subprocess.run([qemu,'-cpu','pentium','-display','none','-machine','pc',
                    '-m','32','-device','isa-debug-exit,iobase=0xf4,iosize=0x04','-bios',image],
                    stdout=log,stderr=subprocess.STDOUT,timeout=30)
            assert free.returncode==133, ('free-QEMU self-check',op,carry,free.returncode)
            run([sys.executable,ROOT/'verif/qemu-trace/gen_trace.py','--qemu',qemu,'--system',
                 '--image',image,'--image-mode','bios','--out',case/'qemu.vtrace',
                 '--max-insn',4000,'--port',41943,
                 *(['--x87'] if args.fp_overlap else [])],case/'qemu.log')
            gold = tracefmt.read_trace(str(case/'qemu.vtrace'))
            assert int(gold.records[-1]['edi'],0)==0xa1fa0001
            for name,binary in [('control',args.control),('candidate',args.candidate)]:
                traces = {}
                for mode in ('cycle','cycle-func'):
                    path = case/f'{name}.{mode}.vtrace'
                    run([binary.resolve(),'--'+mode,'--l1-axi','--system','--image',image,
                         *(['--x87'] if args.fp_overlap else []),
                         '--out',path,'--max-insn',4000,'--max-cycles',3000000,
                         '--quiesce',200000,'+ven_faultlog','+ven_uop_hit_pc=00008013',
                         *(['+ven_fp_async_log'] if args.fp_overlap else [])],
                        case/f'{name}.{mode}.log',env=dict(os.environ,VEN_PIPE_RETIRE_WITNESS='1',
                                                        VEN_UOP_PROBE_PC='0x8013'))
                    traces[mode] = tracefmt.read_trace(str(path))
                    assert [r['pc'] for r in traces[mode].records]==[r['pc'] for r in gold.records]
                cyc,state = traces['cycle'],traces['cycle-func']
                ends = [i for i in range(len(cyc.records))
                        if i+1==len(cyc.records) or cyc.records[i]['cyc']!=cyc.records[i+1]['cyc']]
                with (case/f'{name}.compare.log').open('w') as log:
                    assert compare.compare_func(tracefmt.Trace(gold.hdr,[gold.records[i] for i in ends]),
                        tracefmt.Trace(state.hdr,[state.records[i] for i in ends]),args.fp_overlap,0xffffffff,False,20,log)==0
                log = (case/f'{name}.cycle.log').read_text()
                validate_source_events(log)
                if args.fp_overlap and name == 'candidate':
                    assert re.search(r'^\[FP-ASYNC-DRAIN\] pc=00008013 pending=1 ', log, re.M), \
                        'no pending-FP fault/walk drain at the source instruction'
                print(f'op={op} CF={carry} {name}: {len(ends)} QEMU groups; precise source fault/retry',flush=True)
    print(('FP-' if args.fp_overlap else 'MEM-CHAIN-' if args.memory_chain else '') +
          'ALU-MEMORY-FAULT-OK (14 cases, both binaries; no saved state)')


if __name__=='__main__':
    main()
