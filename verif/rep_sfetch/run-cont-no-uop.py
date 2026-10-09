#!/usr/bin/env python3
"""Cold UV-fast REP A/B, full pinned-QEMU system traces and ownership witnesses.

Retains every record including the normal ISA debug-exit OUT. No terminal
trimming, selected-record comparison, oracle patch or cycle-band change.
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

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO / 'verif/diff'), str(REPO / 'verif/sys')]
import tracefmt
import check_faultlog
from x87_event_compare import compare_complete


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, data):
    with path.open('x') as stream:
        json.dump(data, stream, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control', 'candidate', 'out'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--suite', choices=('main', 'page-smc'), default='main')
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    models = {n: getattr(args, n).resolve(strict=True) for n in ('control', 'candidate')}
    profiles, pins = {}, {}
    for name, tb in models.items():
        stamp = tb.parent / 'Vventium_top__verFiles.dat'
        command = next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        profiles[name] = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command
        assert {'VEN_L1_AXI', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_FE_PIPE',
                'VEN_REP_MOVS_CONT', 'VEN_REP_MOVS_LOAD_FUSE', 'VEN_REP_MOVS_STREAM'} <= profiles[name]
        assert not {'VEN_UOPCACHE', 'VEN_UOP_SFETCH', 'VTM_NO_DPI', 'SYNTHESIS',
                    'VEN_SYS_FASTPATH_ALL'} & profiles[name]
        pins.update({str(p): sha(p) for p in (tb, stamp)})
    assert profiles['candidate'] == profiles['control'] | {'VEN_REP_CONT_NO_UOP'}
    assert 'VEN_REP_CONT_NO_UOP' not in profiles['control']
    basic = REPO / 'verif/rep_sfetch/rep-no-uop.S'
    faults = REPO / 'verif/sys/tests/prepsfetch/prepsfetch.S'
    linker = REPO / 'verif/sys/tests/ppage/ppage.ld'
    qemu = REPO / 'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__), basic, faults, linker, qemu,
              REPO / 'verif/qemu-trace/gen_trace.py', REPO / 'verif/diff/tracefmt.py',
              REPO / 'verif/diff/compare.py', REPO / 'verif/sys/x87_event_compare.py',
              REPO / 'verif/sys/check_faultlog.py'):
        pins[str(p)] = sha(p)
    save(args.out / 'inputs.json', pins)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VEN_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(TMPDIR=str(args.out), PYTHONDONTWRITEBYTECODE='1')

    def run(argv, leaf, name, expected=0, latency=0):
        command = ['timeout', '--signal=TERM', '--kill-after=3s', '90s', *map(str, argv)]
        save(leaf / (name + '.command.json'), command)
        with (leaf / (name + '.stdout')).open('x') as out, (leaf / (name + '.stderr')).open('x') as err:
            rc = subprocess.run(command, env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)),
                                stdout=out, stderr=err).returncode
        save(leaf / (name + '.exit.json'), {'exit': rc})
        assert rc == expected, (name, rc, expected)
        return (leaf / (name + '.stdout')).read_text() + '\n' + (leaf / (name + '.stderr')).read_text()

    def prepare(case):
        name, source, defines, expected_faults = case
        leaf = args.out / name
        leaf.mkdir()
        obj, elf, image = [leaf / ('fixture.' + ext) for ext in ('o', 'elf', 'bin')]
        run(['gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic', '-fno-pie',
             *['-D' + d for d in defines], '-c', source, '-o', obj], leaf, 'assemble')
        run(['gcc', '-m32', '-static', '-no-pie', '-nostdlib', '-Wl,-T,' + str(linker),
             '-Wl,--build-id=none', obj, '-o', elf], leaf, 'link')
        run(['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', elf, image], leaf, 'binary')
        assert image.stat().st_size == 65536
        symbols = {p[2]: int(p[0], 16) for line in subprocess.check_output(['nm', '-n', elf], text=True).splitlines()
                   if len(p := line.split()) == 3 and p[0] != 'U'}
        try:
            run([qemu, '-machine', 'pc', '-cpu', 'pentium', '-m', '64', '-bios', image,
                 '-display', 'none', '-serial', 'none', '-monitor', 'none', '-no-reboot', '-no-shutdown',
                 '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'], leaf, 'free-qemu', 133)
        except AssertionError as exc:
            if args.suite != 'page-smc':
                raise
            # Diagnose the disagreement without turning it into a waiver:
            # retained error forces this suite's final result to FAIL even
            # if single-step QEMU and both RTL models agree completely.
            result['errors'].append(dict(case=name, phase='free-QEMU',
                                         error=repr(exc), not_waived=True))
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        run([sys.executable, '-B', REPO / 'verif/qemu-trace/gen_trace.py', '--qemu', qemu,
             '--system', '--x87', '--image', image, '--image-mode', 'bios', '--cpu', 'pentium',
             '--out', leaf / 'golden.vtrace', '--max-insn', '10000', '--port', str(port)], leaf, 'golden')
        gold = tracefmt.read_trace(str(leaf / 'golden.vtrace'))
        assert 100 < len(gold.records) < 10000 and int(gold.records[-1]['eax'], 0) & 255 == 0x42
        return name, leaf, image, symbols, gold, expected_faults

    def measure(job):
        prepared, name, latency = job
        case, leaf, image, symbols, gold, expected_faults = prepared
        traces, witness, total = {}, '', 0
        for mode in ('cycle-func', 'cycle'):
            stem = f'{name}-l{latency}-{mode}'
            path = leaf / (stem + '.vtrace')
            text = run([models[name], '+ven_repcontlog', '+ven_faultlog', '--system', '--cosim',
                        '--x87', '--' + mode, '--l1-axi', '--image', image, '--out', path,
                        '--max-insn', '10000', '--max-cycles', '3000000', '--quiesce', '200000'],
                       leaf, stem, 133, latency)
            trace = tracefmt.read_trace(str(path))
            traces[mode] = trace
            assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records], (case, name, 'PC stream')
            assert [r['n'] for r in trace.records] == list(range(len(trace.records)))
            if case.startswith('fault'):
                # Data #DB is a post-instruction trap, not start_fault's
                # canonical log. The trace contract includes a delivery
                # record at the handler PC followed by its first PUSH. Use
                # the next instruction (MOV DR6,EAX) to count one execution,
                # retaining both delivery/PUSH records in the full diff.
                assert sum(int(r['pc'], 0) == symbols['db_handler'] + 1
                           for r in trace.records) == 1
            assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL', text)
            check_faultlog.check_counts(check_faultlog.read_counts(
                (leaf / (stem + '.stdout')).read_text().splitlines()), expected_faults)
            footer = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                                r'after (\d+) retired in (\d+) clocks$', text, re.M)
            assert len(footer) == 1 and int(footer[0][0]) == len(trace.records)
            total = int(footer[0][1])
            if mode == 'cycle-func':
                with (leaf / (stem + '-diff.log')).open('x') as log:
                    assert compare_complete(gold, trace, log) == 0, (case, name, 'complete QEMU diff')
            else:
                witness = (leaf / (stem + '.stdout')).read_text()
        rows = traces['cycle'].records
        pairs = [r for r in rows if r.get('pipe') == 'V' and r.get('paired')]
        arms = re.findall(r'^\[MOVSSTREAM\] ARM .*$', witness, re.M)
        fuses = re.findall(r'^\[MOVSFUSE\] LOAD .*$', witness, re.M)
        takes = re.findall(r'^\[REPCONT\] BOUNDARY .*rep_stos_cont_take=1\b.*$', witness, re.M)
        if name == 'control':
            assert not arms and not fuses and not takes
        if case.startswith('basic'):
            assert any(int(r['pc'], 0) == symbols['pair_v'] for r in pairs), 'missing U/V witness'
            assert bool(arms) == (name == 'candidate') and bool(fuses) == (name == 'candidate')
            for fallback in ('fallback_addr16', 'fallback_word', 'fallback_byte'):
                assert not any(f'pc={symbols[fallback]:08x} ' in arm for arm in arms), fallback
        times = [r['cyc'] for r in rows if 'hot_op' in symbols and int(r['pc'], 0) == symbols['hot_op']]
        return dict(case=case, model=name, latency=latency, records=len(rows), paired_v=len(pairs),
                    stream_arms=len(arms), fused_loads=len(fuses), continuation_takes=len(takes),
                    hot_times=times, total_clocks=total, full_qemu_diff=True)

    cases = [(f'basic-o{o}', basic, [f'OFFSET={o}'], {}) for o in (0, 17, 31)]
    cases.append(('basic-o4095-static', basic, ['OFFSET=4095', 'STATIC_STOS=1'], {}))
    for source in (False, True):
        for debug in (False, True):
            defines = (['PREP_MOVS_SOURCE'] if source else []) + (['PREP_MOVS_DEBUG'] if debug else [])
            counts = {(14, 2): 1, (14, 3): 1 if source else 2}
            if source:
                counts[14, 0] = 1
            cases.append((f'fault-s{int(source)}-d{int(debug)}', faults, defines, counts))
    if args.suite == 'page-smc':
        cases = [('basic-o4095-smc', basic, ['OFFSET=4095'], {})]
    result = dict(passed=False, suite=args.suite, measurements=[], errors=[],
                  gameplay_ipc=None, standard_suite=False)
    try:
        prepared = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            pending = {pool.submit(prepare, case): case[0] for case in cases}
            for future in concurrent.futures.as_completed(pending):
                try:
                    prepared.append(future.result())
                except Exception as exc:
                    result['errors'].append(dict(case=pending[future], phase='prepare',
                        error=repr(exc), traceback=traceback.format_exc()))
        jobs = [(case, name, latency) for case in prepared for name in models for latency in (0, 7)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
            pending = [pool.submit(measure, job) for job in jobs]
            for future in concurrent.futures.as_completed(pending):
                try:
                    result['measurements'].append(future.result())
                except Exception as exc:
                    result['errors'].append(dict(error=repr(exc), traceback=traceback.format_exc()))
        assert len(prepared) == len(cases)
        assert len(result['measurements']) == len(jobs) and not result['errors']
        result['passed'] = True
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc), traceback=traceback.format_exc()))
    finally:
        result['inputs_unchanged'] = all(sha(p) == h for p, h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        save(args.out / 'result.json', result)
    print(json.dumps({k: v for k, v in result.items() if k != 'measurements'}, indent=2), flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
