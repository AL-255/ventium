#!/usr/bin/env python3
"""Bounded full-state QEMU proof for the fresh-capture U/V load pair."""
import argparse
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


def run(argv, path, deadline):
    with path.open('w') as output:
        subprocess.run([str(x) for x in argv], cwd=ROOT, stdout=output,
                       stderr=subprocess.STDOUT, check=True,
                       timeout=min(120, deadline - time.monotonic()))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--candidate', type=Path, required=True)
    p.add_argument('--control', type=Path, required=True)
    p.add_argument('--iterations', type=int, default=256)
    p.add_argument('--case', type=int, choices=(28, 29), default=28)
    args = p.parse_args()
    if not 64 <= args.iterations <= 1000:
        p.error('--iterations must be 64..1000')
    deadline = time.monotonic() + 540
    out = Path(tempfile.mkdtemp(prefix=f'ventium-dual-load-pair-{args.case}.'))
    print(f'Artifacts: {out}', flush=True)
    qemu = ROOT / 'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386'
    if not all(x.is_file() for x in (qemu, args.candidate, args.control)):
        raise RuntimeError('missing QEMU or simulator binary')
    obj, elf, flat = [out / ('test.' + x) for x in ('o', 'elf', 'flat')]
    run(['as', '--32', '--defsym', f'CASE={args.case}', '--defsym',
         f'ITERATIONS={args.iterations}',
         ROOT / 'verif/bench/p54_ipc_cases.s', '-o', obj], out / 'as.log', deadline)
    run(['ld', '-m', 'elf_i386', '-Ttext', '0x08048000', obj, '-o', elf],
        out / 'ld.log', deadline)
    run(['nm', '-n', elf], out / 'nm.log', deadline)
    symbols = {fields[2]: int(fields[0], 16)
               for line in (out / 'nm.log').read_text().splitlines()
               if len(fields := line.split()) == 3}
    run([sys.executable, ROOT / 'verif/tests/elf2flat.py', elf,
         '--out', flat, '--base', '0x08048000'], out / 'flat.log', deadline)
    run([sys.executable, ROOT / 'verif/qemu-trace/gen_trace.py', '--qemu', qemu,
         '--elf', elf, '--out', out / 'qemu.vtrace', '--max-insn',
         args.iterations * 5 + 64, '--port', '41975'], out / 'qemu.log', deadline)
    if 'guest exited, code=0' not in (out / 'qemu.log').read_text():
        raise RuntimeError('QEMU did not exit(0)')
    gold = tracefmt.read_trace(str(out / 'qemu.vtrace'))
    results = {}
    for label, binary in (('control', args.control), ('candidate', args.candidate)):
        traces = {}
        for mode in ('cycle', 'cycle-func'):
            path = out / f'{label}.{mode}.vtrace'
            run([binary, f'--{mode}', '--l1-axi', '--image', flat,
                 '--load', '0x08048000', '--entry', '0x08048000',
                 '--init-esp', gold.records[0]['esp'], '--out', path,
                 '--max-insn', args.iterations * 5 + 64,
                 '--max-cycles', '200000', '--quiesce', '1000'],
                out / f'{label}.{mode}.log', deadline)
            traces[mode] = tracefmt.read_trace(str(path))
            if len(traces[mode].records) != len(gold.records) + 1:
                raise RuntimeError(f'{label}/{mode}: incomplete retirement stream')
            if int(traces[mode].records[-1]['pc'], 0) != symbols['exit_syscall']:
                raise RuntimeError(f'{label}/{mode}: no terminal syscall')
            traces[mode].records.pop()
            if [r['pc'] for r in traces[mode].records] != [r['pc'] for r in gold.records]:
                raise RuntimeError(f'{label}/{mode}: PC stream differs from QEMU')
        cyc, state = traces['cycle'], traces['cycle-func']
        ends = [i for i, row in enumerate(cyc.records)
                if i + 1 == len(cyc.records) or row['cyc'] != cyc.records[i + 1]['cyc']]
        with (out / f'{label}.qemu-compare.log').open('w') as log:
            rc = compare.compare_func(
                tracefmt.Trace(gold.hdr, [gold.records[i] for i in ends]),
                tracefmt.Trace(state.hdr, [state.records[i] for i in ends]),
                False, 0xffffffff, False, 20, log)
        if rc != 0:
            raise RuntimeError(f'{label}: full-state QEMU mismatch')
        starts = [i for i, row in enumerate(cyc.records)
                  if int(row['pc'], 0) == symbols['loop_body']]
        if len(starts) != args.iterations or any(b - a != 5 for a, b in zip(starts, starts[1:])):
            raise RuntimeError(f'{label}: wrong loop work')
        clocks = cyc.records[starts[-1]]['cyc'] - cyc.records[starts[32]]['cyc']
        results[label] = {'instructions': (args.iterations - 33) * 5,
                          'clocks': clocks, 'ipc': (args.iterations - 33) * 5 / clocks,
                          'cycles_per_iteration': clocks / (args.iterations - 33)}
        print(f'{label}: {results[label]["cycles_per_iteration"]:.3f} cycles/loop, '
              f'directed IPC {results[label]["ipc"]:.6f}', flush=True)
    if args.case == 28 and results['candidate']['clocks'] >= results['control']['clocks']:
        raise RuntimeError('distinct-bank load pair did not save an exposed clock')
    if args.case == 29 and results['candidate']['clocks'] != results['control']['clocks']:
        raise RuntimeError('same-bank load pair must remain serialized')
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print('P54-DUAL-LOAD-PAIR-OK (full-state QEMU; not gameplay)', flush=True)


if __name__ == '__main__':
    main()
