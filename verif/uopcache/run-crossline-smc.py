#!/usr/bin/env python3
"""Cold-reset two-source SMC differential using an existing full-P5 binary."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'verif/diff'))
import compare
import tracefmt


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--tb', type=Path, required=True)
    p.add_argument('--source', type=Path, default=ROOT/'verif/uopcache/t_crossline_smc.s',
                   help='Fixture with crossing/pass_exit symbols and three 100-visit phases')
    p.add_argument('--fast-retire-only', action='store_true',
                   help='for alternate fixtures, require fast retirement in every phase without the optional final descriptor counter')
    args = p.parse_args()
    os.fstat(9)
    subprocess.run([ROOT / 'tools/build_scope.sh', '--is-active'], pass_fds=(9,), check=True)
    out = Path(tempfile.mkdtemp(prefix='ventium-crossline-smc.'))
    print(f'Artifacts: {out}', flush=True)

    def run(argv, log, **kwargs):
        with (out / log).open('w') as dest:
            subprocess.run([str(a) for a in argv], stdout=dest, stderr=subprocess.STDOUT,
                           check=True, timeout=120, **kwargs)

    run(['as', '--32', args.source.resolve(), '-o', out / 'test.o'], 'as.log')
    run(['ld', '-m', 'elf_i386', '-T', ROOT / 'verif/rep_sfetch/t_rep_smc.ld',
         '-z', 'max-page-size=0x1000', out / 'test.o', '-o', out / 'test.elf'], 'ld.log')
    run(['nm', '-n', out / 'test.elf'], 'symbols.txt')
    symbols = {s[2]: int(s[0], 16) for line in (out / 'symbols.txt').read_text().splitlines()
               if len(s := line.split()) == 3}
    target = symbols['crossing']
    assert target % 32 == 31
    run([sys.executable, ROOT / 'verif/tests/elf2flat.py', out / 'test.elf',
         '--out', out / 'test.flat', '--base', '0x08048000'], 'flat.log')
    run([sys.executable, ROOT / 'verif/qemu-trace/gen_trace.py', '--qemu',
         ROOT / 'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386',
         '--elf', out / 'test.elf', '--out', out / 'gold.vtrace', '--max-insn', 10000,
         '--port', 41873], 'qemu.log')
    assert 'guest exited, code=0' in (out / 'qemu.log').read_text()
    gold = tracefmt.read_trace(str(out / 'gold.vtrace'))
    traces = {}
    for mode in ('cycle', 'cycle-func'):
        run([args.tb.resolve(), '--' + mode, '--l1-axi', '--image', out / 'test.flat',
             '--load', '0x08048000', '--entry', '0x08048000', '--init-esp', gold.records[0]['esp'],
             '--out', out / f'{mode}.vtrace', '--max-insn', 10000, '--max-cycles', 200000,
             '--quiesce', 1000, f'+ven_uop_hit_pc={target:08x}'], f'{mode}.log',
            env=dict(os.environ, VEN_PIPE_RETIRE_WITNESS='1'))
        trace = tracefmt.read_trace(str(out / f'{mode}.vtrace'))
        assert len(trace.records) == len(gold.records) + 1
        assert int(trace.records[-1]['pc'], 0) == symbols['pass_exit']
        trace.records.pop()
        assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records]
        traces[mode] = trace
    cyc = traces['cycle'].records
    ends = [i for i in range(len(cyc)) if i + 1 == len(cyc) or cyc[i]['cyc'] != cyc[i+1]['cyc']]
    with (out / 'compare.log').open('w') as log:
        assert compare.compare_func(
            tracefmt.Trace(gold.hdr, [gold.records[i] for i in ends]),
            tracefmt.Trace(traces['cycle-func'].hdr, [traces['cycle-func'].records[i] for i in ends]),
            False, 0xffffffff, False, 20, log) == 0
    log = (out / 'cycle.log').read_text()
    hit = re.search(r'watch-hit .* entries=(\d+)', log)
    if not args.fast_retire_only:
        assert hit and int(hit[1]) > 0, 'no supplemental descriptor consumption'
    commits = re.findall(rf'\[PIPE-RETIRE\] pc={target:08x} explicit=(\d)', log)
    assert len(commits) == 300, 'missing SMC phase retirements'
    for phase in range(3):
        assert '1' in commits[phase*100:(phase+1)*100], f'phase {phase} never fast-retired'
    witness = 'fast retirement' if args.fast_retire_only else 'descriptor hit and fast retirement'
    print(f'CROSSLINE-SMC-OK: {len(ends)} QEMU-equivalent groups; '
          f'all three phases have {witness}')


if __name__ == '__main__':
    main()
