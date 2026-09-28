#!/usr/bin/env python3
"""Bounded QEMU full-state and fixed-work A/B for branch-target load priming."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'verif/diff'))
import compare
import tracefmt


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(command, log, deadline):
    remaining = deadline - time.monotonic()
    require(remaining > 0, 'nine-minute microbenchmark budget expired')
    with log.open('w') as output:
        subprocess.run([str(item) for item in command], cwd=ROOT,
                       stdout=output, stderr=subprocess.STDOUT,
                       timeout=min(120, remaining), check=True)


def symtab(path):
    return {p[2]: int(p[0], 16) for line in path.read_text().splitlines()
            if len(p := line.split()) == 3}


def measured_trace(path, gold, sym, iterations):
    trace = tracefmt.read_trace(str(path))
    require(len(trace.records) == len(gold.records) + 1,
            f'{path}: truncated or extra retirement records')
    require(int(trace.records[-1]['pc'], 0) == sym['exit_syscall'],
            f'{path}: missing terminal syscall')
    trace.records.pop()
    require([r['pc'] for r in trace.records] == [r['pc'] for r in gold.records],
            f'{path}: PC stream differs from QEMU')
    require([r['n'] for r in trace.records] == list(range(len(gold.records))),
            f'{path}: duplicate or missing retirement number')
    starts = [i for i, r in enumerate(trace.records)
              if int(r['pc'], 0) == sym['loop_body']]
    require(len(starts) == iterations, f'{path}: incomplete loop')
    require(all(b - a == 6 for a, b in zip(starts, starts[1:])),
            f'{path}: wrong six-instruction loop work')
    if 'cyc' not in trace.records[0]:
        return trace, None
    begin, end = starts[32], starts[-1]
    clocks = trace.records[end]['cyc'] - trace.records[begin]['cyc']
    work = (iterations - 33) * 6
    require(clocks > 0, f'{path}: no measured clocks')
    return trace, {'instructions': work, 'clocks': clocks, 'ipc': work / clocks,
                   'cycles_per_iteration': clocks / (iterations - 33)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--iterations', type=int, default=256)
    parser.add_argument('--case', type=int, choices=(22, 23), default=22,
                        help='22: U branch; 23: paired V branch')
    args = parser.parse_args()
    require(64 <= args.iterations <= 1000, 'iterations must be 64..1000')
    subprocess.run([ROOT / 'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    deadline = time.monotonic() + 540
    out = Path(tempfile.mkdtemp(prefix=f'ventium-branch-target-prime-case{args.case}.'))
    print(f'Artifacts: {out}', flush=True)
    qemu = ROOT / 'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386'
    binaries = {'control': args.control.resolve(), 'candidate': args.candidate.resolve()}
    require(all(p.is_file() for p in [qemu, *binaries.values()]), 'missing binary')
    def digest(path):
        with path.open('rb') as stream:
            return hashlib.file_digest(stream, 'sha256').hexdigest()
    (out / 'binaries.sha256').write_text(''.join(
        f'{digest(p)}  {p}\n' for p in [qemu, *binaries.values()]))
    obj, elf, flat = [out / f'test.{suffix}' for suffix in ('o', 'elf', 'flat')]
    run(['as', '--32', '--defsym', f'CASE={args.case}', '--defsym',
         f'ITERATIONS={args.iterations}', ROOT / 'verif/bench/p54_ipc_cases.s',
         '-o', obj], out / 'as.log', deadline)
    run(['ld', '-m', 'elf_i386', '-Ttext', '0x08048000', obj, '-o', elf],
        out / 'ld.log', deadline)
    run(['nm', '-n', elf], out / 'nm.log', deadline)
    sym = symtab(out / 'nm.log')
    run([sys.executable, ROOT / 'verif/tests/elf2flat.py', elf,
         '--out', flat, '--base', '0x08048000'], out / 'flat.log', deadline)
    run([sys.executable, ROOT / 'verif/qemu-trace/gen_trace.py',
         '--qemu', qemu, '--elf', elf, '--out', out / 'qemu.vtrace',
         '--max-insn', args.iterations * 6 + 64, '--port', 41947 + args.case],
        out / 'qemu.log', deadline)
    require('guest exited, code=0' in (out / 'qemu.log').read_text(),
            'QEMU did not exit(0)')
    gold = tracefmt.read_trace(str(out / 'qemu.vtrace'))
    results = {}
    for label, binary in binaries.items():
        traces = {}
        for mode in ('cycle', 'cycle-func'):
            path = out / f'{label}.{mode}.vtrace'
            run([binary, f'--{mode}', '--l1-axi', '--image', flat,
                 '--load', '0x08048000', '--entry', '0x08048000',
                 '--init-esp', gold.records[0]['esp'], '--out', path,
                 '--max-insn', args.iterations * 6 + 64,
                 '--max-cycles', '200000', '--quiesce', '1000'],
                out / f'{label}.{mode}.log', deadline)
            traces[mode], _ = measured_trace(path, gold, sym, args.iterations)
        cyc, state = traces['cycle'], traces['cycle-func']
        clocks = [r['cyc'] for r in cyc.records]
        ends = [i for i in range(len(clocks))
                if i + 1 == len(clocks) or clocks[i] != clocks[i + 1]]
        with (out / f'{label}.qemu-compare.log').open('w') as log:
            rc = compare.compare_func(
                tracefmt.Trace(gold.hdr, [gold.records[i] for i in ends]),
                tracefmt.Trace(state.hdr, [state.records[i] for i in ends]),
                False, 0xffffffff, False, 20, log)
        require(rc == 0, f'{label}: full-state QEMU mismatch')
        _, results[label] = measured_trace(
            out / f'{label}.cycle.vtrace', gold, sym, args.iterations)
        print(f'{label}: {results[label]["cycles_per_iteration"]:.3f} '
              f'cycles/iteration, directed IPC {results[label]["ipc"]:.6f}',
              flush=True)
    require(results['candidate']['clocks'] < results['control']['clocks'],
            'branch-target prime did not save an exposed clock')
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('P54-BRANCH-TARGET-PRIME-OK (full-state QEMU; not gameplay)', flush=True)


if __name__ == '__main__':
    main()
