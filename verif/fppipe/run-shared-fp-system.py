#!/usr/bin/env python3
"""Cold shared-FP/INT3 A/B, every QEMU retirement, never grouped or filtered."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import traceback

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/diff'))
sys.path.insert(0, str(REPO/'verif/sys'))
import tracefmt
from x87_event_compare import compare_complete


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control', 'candidate', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models = {name: getattr(args, name).resolve(strict=True)
              for name in ('control', 'candidate')}
    profiles, pins = [], {}
    for binary in models.values():
        stamp = binary.parent/'Vventium_top__verFiles.dat'
        command = next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        defs = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command
        assert {'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_L1_AXI',
                'VEN_FP_SHARED', 'VEN_FP_ARITH_STREAM', 'VEN_FP_ARITH_FWD',
                'VEN_FP_ASYNC', 'VEN_FP_ASYNC_BRANCH', 'VEN_FP_FXCH_QUEUE'} <= defs
        assert not {'VTM_NO_DPI', 'SYNTHESIS', 'VEN_SYS_FASTPATH_ALL'} & defs
        profiles.append(defs)
        pins.update({str(p): sha(p) for p in (binary, stamp)})
    assert profiles[0] == profiles[1]
    fixtures = REPO/'verif/sys/tests/px87stk'
    source, linker = fixtures/'px87streamtrap.S', fixtures/'px87stk.ld'
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__), source, linker, qemu,
              REPO/'verif/qemu-trace/gen_trace.py', REPO/'verif/diff/compare.py',
              REPO/'verif/diff/tracefmt.py', REPO/'verif/sys/x87_event_compare.py'):
        pins[str(p)] = sha(p)
    (args.out/'inputs.json').write_text(json.dumps(pins, indent=2)+'\n')
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('VEN_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(TMPDIR=str(args.out), PYTHONDONTWRITEBYTECODE='1')

    def run(command, leaf, name, expected=0, latency=0):
        command = ['timeout', '--signal=TERM', '--kill-after=3s', '60s', *map(str, command)]
        (leaf/(name+'.command.json')).write_text(json.dumps(command, indent=2)+'\n')
        with (leaf/(name+'.stdout')).open('x') as output, (leaf/(name+'.stderr')).open('x') as errors:
            code = subprocess.run(command, env=dict(env, AXI_RLAT=str(latency),
                AXI_WLAT=str(latency)), stdout=output, stderr=errors).returncode
        (leaf/(name+'.exit')).write_text(str(code)+'\n')
        assert code == expected, (name, code, expected)

    def check(kind):
        leaf = args.out/kind
        leaf.mkdir()
        defs = {'stream': [], 'fxch': ['--defsym', 'FXCH_QUEUE=1'],
                'branch': ['--defsym', 'BRANCH_TRAP=1']}[kind]
        run(['as', '--32', *defs, source, '-o', leaf/'test.o'], leaf, 'assemble')
        run(['ld', '-m', 'elf_i386', '-T', linker, leaf/'test.o', '-o', leaf/'test.elf'], leaf, 'link')
        run(['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000',
             leaf/'test.elf', leaf/'test.bin'], leaf, 'binary')
        image = leaf/'test.bin'
        assert image.stat().st_size == 65536
        run([qemu, '-machine', 'pc', '-cpu', 'pentium', '-m', '64', '-bios', image,
             '-display', 'none', '-serial', 'none', '-monitor', 'none', '-no-reboot',
             '-no-shutdown', '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'], leaf, 'free-qemu', 133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        run([sys.executable, '-B', REPO/'verif/qemu-trace/gen_trace.py', '--qemu', qemu,
             '--system', '--x87', '--image', image, '--image-mode', 'bios', '--cpu', 'pentium',
             '--out', leaf/'golden.vtrace', '--max-insn', '5000', '--port', str(port)], leaf, 'golden')
        gold = tracefmt.read_trace(str(leaf/'golden.vtrace'))
        assert 0 < len(gold.records) < 5000 and int(gold.records[-1]['eax'], 0) == 0x42
        rows = []
        for latency in (0, 7):
            for name, binary in models.items():
                traces = {}
                for mode in ('cycle-func', 'cycle'):
                    stem = f'{name}-lat{latency}-{mode}'
                    path = leaf/(stem+'.vtrace')
                    run([binary, '--system', '--cosim', '--x87', '--l1-axi', '--'+mode,
                         '--image', image, '--out', path, '--max-insn', '5000',
                         '--max-cycles', '3000000', '--quiesce', '200000', '+ven_faultlog'],
                        leaf, stem, 133, latency)
                    trace = tracefmt.read_trace(str(path))
                    assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records]
                    assert [r['n'] for r in trace.records] == list(range(len(trace.records)))
                    if mode == 'cycle-func':
                        assert trace.mode == 'func' and trace.hdr.get('sys') is True and trace.x87
                    else:
                        assert trace.mode == 'cycle' and not trace.x87
                    text = (leaf/(stem+'.stdout')).read_text()+'\n'+(leaf/(stem+'.stderr')).read_text()
                    assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL', text)
                    footer = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                                        r'after (\d+) retired in (\d+) clocks$', text, re.M)
                    assert len(footer) == 1 and int(footer[0][0]) == len(trace.records)
                    traces[mode] = trace
                    if mode == 'cycle-func':
                        with (leaf/(stem+'-diff.log')).open('x') as log:
                            assert compare_complete(gold, trace, log) == 0, (kind, name, latency, 'full differential')
                cycle = traces['cycle'].records
                paired_v = sum(r.get('pipe') == 'V' and r.get('paired', False) for r in cycle)
                assert paired_v > 0, (kind, name, latency, 'no actual U/V pairing')
                trap_pc = 0x800e if kind == 'branch' else 0x800c
                assert sum(int(r['pc'], 0) == trap_pc for r in cycle) == 64
                bursts = 0
                for i in range(len(cycle)-10):
                    if kind == 'fxch':
                        block = cycle[i:i+11]
                        if [int(r['pc'], 0) for r in block] == [0x8000, 0x8002, *range(0x8004, 0x800d)]:
                            if int(block[1]['cyc'])-int(block[0]['cyc']) == 1:
                                assert int(block[-1]['cyc'])-int(block[0]['cyc']) >= 35
                                bursts += 1
                    else:
                        block = cycle[i:i+6]
                        if [int(r['pc'], 0) for r in block] == list(range(0x8000, 0x800c, 2)):
                            bursts += [int(r['cyc'])-int(block[0]['cyc']) for r in block] == list(range(6))
                assert bursts >= 8, (kind, name, latency, 'missing real overlapping-FP witness', bursts)
                branch_overlap = 0
                if kind == 'branch':
                    # The branch immediately after the sixth streamed FADD
                    # must retire on the next edge, while that FP owner still
                    # occupies the three-stage unit; not merely after a drain.
                    branch_overlap = sum(
                        int(r['pc'], 0) == 0x800a and
                        int(cycle[i+1]['pc'], 0) == 0x800c and
                        int(cycle[i+1]['cyc'])-int(r['cyc']) == 1
                        for i, r in enumerate(cycle[:-1]))
                    assert branch_overlap >= 55, ('no FP/integer-branch overlap', branch_overlap)
                rows.append(dict(case=kind, model=name, latency=latency,
                    records=len(gold.records), bursts=bursts, paired_v=paired_v,
                    branch_overlap=branch_overlap, full_qemu_diff=True))
        return rows

    result = dict(passed=False, cases=[], errors=[], gameplay_ipc=None, standard_suite=False)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            pending = {pool.submit(check, kind): kind for kind in ('stream', 'fxch', 'branch')}
            for future in concurrent.futures.as_completed(pending):
                try:
                    result['cases'].extend(future.result())
                except Exception as error:
                    result['errors'].append(dict(case=pending[future], error=repr(error),
                                                 traceback=traceback.format_exc()))
        result['passed'] = not result['errors'] and len(result['cases']) == 12
    finally:
        result['inputs_unchanged'] = all(sha(p) == h for p, h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        (args.out/'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result, indent=2))
    assert result['passed']


if __name__ == '__main__':
    main()
