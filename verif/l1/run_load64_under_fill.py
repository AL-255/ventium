#!/usr/bin/env python3
"""Full-record x87 regression and actual wide-response witness under D refill.

Use separately qualified private preexit QEMU, with the same guest environment
as the original pinned oracle. The original complete trace must be an exact
prefix; every observed terminal record is compared too. No trace trimming,
new field masks, direct cache state writes, or gameplay acceptance.
"""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'verif/diff'))
import compare
import tracefmt


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(path, value):
    with path.open('x') as f:
        json.dump(value, f, indent=2)


def cases():
    # All contained eight-byte offsets, then every insufficient-line tail.
    return ([('d', offset, 1) for offset in range(32)] +
            [('d', offset, 0) for offset in (0, 25, 29)] + [('i', 0, 1)])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ('parent', 'candidate', 'pinned', 'observer', 'out'):
        ap.add_argument('--' + name, type=Path, required=True)
    ap.add_argument('--jobs', type=int, default=8, choices=range(1, 33))
    args = ap.parse_args()
    assert __debug__
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch) and not args.out.exists()
    args.out.mkdir()
    assert sha(args.observer) == '52a9ca27d2d1bb40a360a7c2e881b8fe63b0795f285ae823b96e33e75ef0ff31'
    env = {k:v for k,v in os.environ.items()
           if not k.startswith(('AXI_', 'QEMU_', 'VEN_', 'VTM_QEMU', 'TB_'))}
    env.update(TMPDIR=str(scratch), PYTHONDONTWRITEBYTECODE='1')
    paths = [Path(__file__), args.parent, args.candidate, args.pinned, args.observer,
             REPO/'verif/l1/t_load64_under_ifill.s', REPO/'verif/l1/t_load64_under_dfill.s',
             REPO/'verif/tests/elf2flat.py', REPO/'verif/qemu-trace/gen_trace.py',
             REPO/'verif/diff/compare.py', REPO/'verif/diff/tracefmt.py']
    pins = {str(p.resolve()):sha(p) for p in paths}
    definitions = {}
    for name in ('parent', 'candidate'):
        binary = getattr(args, name)
        stamp = binary.parent/'Vventium_top__verFiles.dat'
        pins[str(stamp.resolve())] = sha(stamp)
        command = next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
        definitions[name] = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command
        assert {'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
                'VEN_L1D_HIT_UNDER_FILL', 'VEN_FP_LOAD64'} <= definitions[name]
    assert definitions['candidate'] == definitions['parent'] | {'VEN_FP_LOAD64_UNDER_FILL'}
    assert 'VEN_FP_LOAD64_UNDER_FILL' not in definitions['parent']
    save(args.out/'plan.json', dict(pins=pins, cases=cases(), latencies=[0, 3, 15],
         quiesce=2000, standard_suite=False, gameplay_ipc=None, jobs=args.jobs))

    def case(spec):
        fill, offset, wide = spec
        name = f'{fill}fill-offset{offset}-wide{wide}'
        out = args.out/name; out.mkdir()
        row = dict(name=name, passed=False, errors=[], runs=[])
        commands = []

        def run(argv, label, extra=None):
            argv = list(map(str, argv))
            commands.append(dict(argv=argv, log=label, environment=extra or {}))
            with (out/(label+'.log')).open('x') as log:
                proc = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT,
                                      env=env | (extra or {}), timeout=60)
            assert proc.returncode == 0, (label, proc.returncode)

        try:
            source = REPO/f'verif/l1/t_load64_under_{fill}fill.s'
            obj, elf, flat = (out/('test.'+ext) for ext in ('o', 'elf', 'flat'))
            run(['as', '--32', '--defsym', f'SOURCE_OFFSET={offset}', '--defsym',
                 f'SOURCE_WIDE={wide}', source, '-o', obj], 'as')
            run(['ld', '-m', 'elf_i386', '-Ttext', '0x08048000', obj, '-o', elf], 'ld')
            run([sys.executable, REPO/'verif/tests/elf2flat.py', elf, '--out', flat,
                 '--base', '0x08048000'], 'flat')
            symbols = {v[2]:int(v[0], 16) for line in subprocess.check_output(
                ['nm', '-n', str(elf)], text=True).splitlines() if len(v:=line.split()) == 3}
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
            for label in ('pinned', 'observer'):
                # Same environment even when the original ignores the option:
                # otherwise Linux argv/env placement changes initial ESP.
                run([sys.executable, REPO/'verif/qemu-trace/gen_trace.py', '--qemu',
                     getattr(args, label), '--elf', elf, '--out', out/(label+'.vtrace'),
                     '--max-insn', '3000', '--port', port, '--x87'], label,
                    {'VTM_QEMU_GDB_PREEXIT':'1'})
                assert 'guest exited, code=0' in (out/(label+'.log')).read_text()
            gold = tracefmt.read_trace(str(out/'observer.vtrace'))
            original = tracefmt.read_trace(str(out/'pinned.vtrace'))
            assert gold.records[:-1] == original.records
            assert int(gold.records[-1]['pc'], 0) == symbols['pass_exit']
            for latency in (0, 3, 15):
                records, timing, takes = {}, {}, {}
                for label in ('parent', 'candidate'):
                    tag = f'{label}-lat{latency}'
                    trace_path = out/(tag+'.vtrace')
                    run([getattr(args, label), '--cycle-func', '--x87', '--l1-axi',
                         '--image', flat, '--load', '0x08048000', '--entry', '0x08048000',
                         '--init-esp', gold.records[0]['esp'], '--out', trace_path,
                         '--max-insn', '3000', '--max-cycles', '1000000',
                         '--quiesce', '2000', '+ven_fpload64log',
                         *([f'+ven_fpload64_pc={symbols["source_probe"]:x}'] if fill == 'd' else [])], tag,
                        {'AXI_RLAT':str(latency), 'AXI_WLAT':'0'})
                    trace = tracefmt.read_trace(str(trace_path)); records[label] = trace.records
                    with (out/(tag+'.compare.log')).open('x') as log:
                        assert compare.compare_func(gold, trace, True, 0xffffffff,
                                                    False, 20, log) == 0, tag
                    text = (out/(tag+'.log')).read_text()
                    assert not re.search(r'%Error|%Fatal|Assertion failed|tb: FLT', text)
                    found = re.findall(r'\[FPLOAD64\] complete resident operands=(\d+)', text)
                    assert len(found) == 1
                    takes[label] = int(found[0])
                    retired = re.findall(r'tb: retired (\d+) instructions in (\d+) clocks', text)
                    assert len(retired) == 1 and int(retired[0][0]) == len(gold.records)
                    timing[label] = int(retired[0][1])
                assert records['parent'] == records['candidate']
                eligible = fill == 'd' and wide and offset <= 24
                if eligible:
                    assert takes == dict(parent=0, candidate=16), takes
                    assert timing['candidate'] <= timing['parent'], timing
                    if latency == 0:
                        assert timing['candidate'] < timing['parent'], timing
                else:
                    assert takes['candidate'] == takes['parent'], takes
                    assert timing['candidate'] == timing['parent'], timing
                row['runs'].append(dict(latency=latency, records=len(gold.records),
                    clocks=timing, wide_takes=takes, full_architectural_match=True))
            row['passed'] = True
        except Exception as exc:
            row['errors'].append(repr(exc))
        finally:
            save(out/'commands.json', commands); save(out/'closed.json', row)
        return row

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        rows = list(pool.map(case, cases()))
    unchanged = all(sha(p) == h for p,h in pins.items())
    result = dict(passed=all(row['passed'] for row in rows) and unchanged,
                  cases=rows, inputs_unchanged=unchanged, standard_suite=False,
                  gameplay_ipc=None, physical_board=False)
    save(args.out/'closed.json', result)
    print(json.dumps(dict(passed=result['passed'], cases=len(rows), failures=[
        (row['name'], row['errors']) for row in rows if not row['passed']])), flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
