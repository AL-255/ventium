#!/usr/bin/env python3
"""UV-fast resolved control target diagnostic, complete QEMU architectural diff.

Eight QEMU workers (each QEMU is multi-threaded), then 32 single-threaded RTL
workers. No snapshots, forced ready, trace trimming, exception masks or bypass.
"""
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

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path[:0] = [str(REPO / 'verif/diff'), str(REPO / 'verif/sys')]
import tracefmt
from x87_event_compare import compare_complete


def sha(p):
    with Path(p).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(p, value):
    with p.open('x') as stream:
        json.dump(value, stream, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control', 'candidate', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--smoke', action='store_true')
    parser.add_argument('--feature', choices=('VEN_P54_CTRL_TARGET_SYSTEM', 'VEN_IFETCH_AUTH_MULTI'),
                        default='VEN_P54_CTRL_TARGET_SYSTEM')
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models = {name: getattr(args, name).resolve(strict=True) for name in ('control', 'candidate')}
    pins, profiles = {}, {}
    for name, tb in models.items():
        stamp = tb.parent / 'Vventium_top__verFiles.dat'
        command = next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        profiles[name] = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command
        assert {'VEN_L1_AXI', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_FE_PIPE',
                'VEN_FP_SHARED', 'VEN_FP_ASYNC_STREAM', 'VEN_FP_MEM_QUEUE',
                'VEN_FP_LOAD_EARLY_CMD', 'VEN_FP_OPERAND_OVERLAP'} <= profiles[name]
        assert not {'VEN_UOPCACHE', 'VTM_NO_DPI', 'SYNTHESIS', 'VEN_SYS_FASTPATH_ALL'} & profiles[name]
        pins.update({str(p): sha(p) for p in (tb, stamp)})
    assert profiles['candidate'] == profiles['control'] | {args.feature}
    assert args.feature not in profiles['control']
    source = REPO / 'verif/fe_pipe/system-target-read.S'
    linker = REPO / 'verif/sys/tests/ppage/ppage.ld'
    qemu = REPO / 'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__), source, linker, qemu, REPO / 'verif/qemu-trace/gen_trace.py',
              REPO / 'verif/diff/tracefmt.py', REPO / 'verif/diff/compare.py',
              REPO / 'verif/sys/x87_event_compare.py'):
        pins[str(p)] = sha(p)
    save(args.out / 'inputs.json', pins)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VEN_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(TMPDIR=str(args.out), PYTHONDONTWRITEBYTECODE='1')

    def run(command, leaf, name, expected=0, latency=0):
        argv = ['timeout', '--signal=TERM', '--kill-after=3s', '60s', *map(str, command)]
        save(leaf / (name + '.command.json'), argv)
        with (leaf / (name + '.stdout')).open('x') as out, (leaf / (name + '.stderr')).open('x') as err:
            rc = subprocess.run(argv, env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)),
                                stdout=out, stderr=err).returncode
        save(leaf / (name + '.exit.json'), {'exit': rc})
        assert rc == expected, (name, rc, expected)
        return (leaf / (name + '.stdout')).read_text() + '\n' + (leaf / (name + '.stderr')).read_text()

    def prepare(case):
        kind, pop, reloc, offset, cw = case
        leaf = args.out / f'k{kind}-p{pop}-r{reloc}-o{offset}-cw{cw:x}'
        leaf.mkdir()
        obj, elf, image = [leaf / ('fixture.' + ext) for ext in ('o', 'elf', 'bin')]
        run(['gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic', '-fno-pie',
             f'-DKIND={kind}', f'-DPOP_KIND={pop}', f'-DRELOC={reloc}', f'-DOFFSET={offset}',
             f'-DCONTROL_WORD={cw}', '-c', source, '-o', obj], leaf, 'assemble')
        run(['gcc', '-m32', '-static', '-no-pie', '-nostdlib', '-Wl,-T,' + str(linker),
             '-Wl,--build-id=none', obj, '-o', elf], leaf, 'link')
        run(['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', elf, image], leaf, 'binary')
        assert image.stat().st_size == 65536
        symbols = {p[2]: int(p[0], 16) for line in subprocess.check_output(['nm', '-n', elf], text=True).splitlines()
                   if len(p := line.split()) == 3 and p[0] != 'U'}
        assert symbols['hot_loop'] % 32 == offset
        run([qemu, '-machine', 'pc', '-cpu', 'pentium', '-m', '64', '-bios', image, '-display', 'none',
             '-serial', 'none', '-monitor', 'none', '-no-reboot', '-no-shutdown',
             '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'], leaf, 'free-qemu', 133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        run([sys.executable, '-B', REPO / 'verif/qemu-trace/gen_trace.py', '--qemu', qemu,
             '--system', '--x87', '--image', image, '--image-mode', 'bios', '--cpu', 'pentium',
             '--out', leaf / 'golden.vtrace', '--max-insn', '5000', '--port', str(port)], leaf, 'golden')
        gold = tracefmt.read_trace(str(leaf / 'golden.vtrace'))
        assert 100 < len(gold.records) < 5000 and int(gold.records[-1]['eax'], 0) & 255 == 0x42
        return case, leaf, image, symbols, gold

    def measure(job):
        prepared, name, latency = job
        case, leaf, image, symbols, gold = prepared
        traces = {}
        total_clocks = 0
        for mode in ('cycle-func', 'cycle'):
            stem = f'{name}-l{latency}-{mode}'
            path = leaf / (stem + '.vtrace')
            text = run([models[name], '+ven_fetchdbg', '--system', '--cosim', '--x87', '--' + mode, '--l1-axi',
                        '--image', image, '--out', path, '--max-insn', '5000', '--max-cycles', '3000000',
                        '--quiesce', '200000'], leaf, stem, 133, latency)
            trace = tracefmt.read_trace(str(path))
            traces[mode] = trace
            assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records]
            assert [r['n'] for r in trace.records] == list(range(len(trace.records)))
            assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL', text)
            footer = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                                r'after (\d+) retired in (\d+) clocks$', text, re.M)
            assert len(footer) == 1 and int(footer[0][0]) == len(trace.records)
            total_clocks = int(footer[0][1])
            if mode == 'cycle-func':
                assert trace.mode == 'func' and trace.hdr.get('sys') is True and trace.x87
                with (leaf / (stem + '-diff.log')).open('x') as log:
                    assert compare_complete(gold, trace, log) == 0, (case, name, latency, 'full QEMU diff')
        rows = traces['cycle'].records
        hits = [i for i, r in enumerate(rows) if int(r['pc'], 0) == symbols['hot_loop']]
        assert len(hits) == 16
        pairs = [r for r in rows if r.get('pipe') == 'V' and r.get('paired')]
        assert any(int(r['pc'], 0) == symbols['pair_v'] for r in pairs), 'missing UV witness'
        warm = [rows[b]['cyc'] - rows[a]['cyc'] for a, b in zip(hits[3:-1], hits[4:])]
        return dict(case=case, model=name, latency=latency, warm_cycles=warm,
                    records=len(rows), paired_v=len(pairs), full_qemu_diff=True,
                    total_clocks=total_clocks)

    cases = [(k, 0, r, o, 0x37f) for k in (0, 1, 2, 3, 4, 5, 6, 7, 8)
             for r in (0, 1) for o in ((17,) if args.smoke else (0, 17, 18, 31))]
    result = dict(passed=False, feature=args.feature, measurements=[], errors=[],
                  gameplay_ipc=None, standard_suite=False)
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            prepared = list(pool.map(prepare, cases))
        jobs = [(case, name, latency) for case in prepared for name in models for latency in (0, 7)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
            pending = {pool.submit(measure, job): job[:1] for job in jobs}
            for future in concurrent.futures.as_completed(pending):
                try:
                    result['measurements'].append(future.result())
                except Exception as exc:
                    result['errors'].append(dict(error=repr(exc), traceback=traceback.format_exc()))
        assert len(result['measurements']) == len(jobs) and not result['errors']
        indexed = {(tuple(r['case']), r['model'], r['latency']): r for r in result['measurements']}
        gains = []
        for case in cases:
            for latency in (0, 7):
                a = indexed[case, 'control', latency]['warm_cycles']
                b = indexed[case, 'candidate', latency]['warm_cycles']
                assert sum(b) <= sum(a), ('performance regression', case, latency, a, b)
                gains.append(dict(case=case, latency=latency, control=a, candidate=b,
                                  fraction=1 - sum(b) / sum(a)))
        result['actual_warm_cycle_gain'] = any(r['fraction'] > 0 for r in gains)
        result['gains'] = gains
        result['separate_leaf_and_fault_tests_required'] = True
        assert result['actual_warm_cycle_gain']
        result.update(passed=True, gains=gains)
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc), traceback=traceback.format_exc()))
    finally:
        result['inputs_unchanged'] = all(sha(p) == h for p, h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        save(args.out / 'result.json', result)
    print(json.dumps({k: v for k, v in result.items() if k not in ('measurements', 'gains')}, indent=2), flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
