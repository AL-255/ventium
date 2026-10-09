#!/usr/bin/env python3
"""Complete cold-system QEMU differential + measured ordered-m64 overlap.

No snapshot, shortened trace, state normalization or forced readiness. Eight
QEMU producers, then 32 RTL workers; invoke inside the bounded build scope.
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
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import tracefmt
import check_faultlog
from x87_event_compare import compare_complete


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, value):
    with p.open('x') as f:
        json.dump(value, f, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('control', 'candidate', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--smoke', action='store_true')
    parser.add_argument('--fault', action='store_true', help='Absent operand page + precise older-FP drain and restart')
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    subprocess.run([REPO/'tools/build_scope.sh', '--is-active'], check=True, close_fds=False)
    args.out.mkdir()
    models = {name: getattr(args, name).resolve(strict=True) for name in ('control', 'candidate')}
    pins, profiles = {}, {}
    for name, tb in models.items():
        stamp = tb.parent/'Vventium_top__verFiles.dat'
        command = next(x for x in stamp.read_text().splitlines() if x.startswith('C '))
        profiles[name] = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command
        assert {'VEN_L1_AXI', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_FE_PIPE',
                'VEN_FP_SHARED', 'VEN_FP_ASYNC_STREAM', 'VEN_FP_MEM_QUEUE',
                'VEN_FP_LOAD_EARLY_CMD', 'VEN_FP_OPERAND_OVERLAP'} <= profiles[name]
        assert not {'VEN_UOPCACHE', 'VTM_NO_DPI', 'SYNTHESIS', 'VEN_SYS_FASTPATH_ALL'} & profiles[name]
        pins.update({str(p): sha(p) for p in (tb, stamp)})
    assert profiles['candidate'] == profiles['control'] | {'VEN_FP_MEM_QUEUE64'}
    assert 'VEN_FP_MEM_QUEUE64' not in profiles['control']
    source = REPO/'verif/fe_pipe'/('fp-mem64-fault.S' if args.fault else 'fp-mem64-queue.S')
    linker = REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__), source, linker, qemu, REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py', REPO/'verif/diff/compare.py',
              REPO/'verif/sys/x87_event_compare.py', REPO/'verif/sys/check_faultlog.py'):
        pins[str(p)] = sha(p)
    save(args.out/'inputs.json', pins)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VEN_', 'TB_', 'AXI_', 'QEMU_'))}
    env.update(TMPDIR=str(args.out), PYTHONDONTWRITEBYTECODE='1')

    def run(command, leaf, name, expected=0, latency=0):
        argv = ['timeout', '--signal=TERM', '--kill-after=3s', '60s', *map(str, command)]
        save(leaf/(name+'.command.json'), argv)
        with (leaf/(name+'.stdout')).open('x') as out, (leaf/(name+'.stderr')).open('x') as err:
            rc = subprocess.run(argv, env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)),
                                stdout=out, stderr=err).returncode
        save(leaf/(name+'.exit.json'), dict(exit=rc))
        assert rc == expected, (name, rc, expected, str(leaf))
        return (leaf/(name+'.stdout')).read_text()+'\n'+(leaf/(name+'.stderr')).read_text()

    def prepare(case):
        kind, drain, reloc, offset = case
        leaf = args.out/(f'k{kind}-fault-split{offset}' if args.fault else f'k{kind}-d{drain}-r{reloc}-o{offset}')
        leaf.mkdir()
        obj, elf, image = [leaf/('fixture.'+ext) for ext in ('o', 'elf', 'bin')]
        run(['gcc', '-m32', '-ffreestanding', '-nostdlib', '-fno-pic', '-fno-pie',
             f'-DKIND={kind}', f'-DDRAIN={drain}', f'-DRELOC={reloc}', f'-DDATA_OFFSET={offset}', f'-DSPLIT={offset}',
             '-c', source, '-o', obj], leaf, 'assemble')
        run(['gcc', '-m32', '-static', '-no-pie', '-nostdlib', '-Wl,-T,'+str(linker),
             '-Wl,--build-id=none', obj, '-o', elf], leaf, 'link')
        run(['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', elf, image], leaf, 'binary')
        assert image.stat().st_size == 65536
        symbols = {p[2]: int(p[0], 16) for line in subprocess.check_output(['nm', '-n', elf], text=True).splitlines()
                   if len(p := line.split()) == 3 and p[0] != 'U'}
        run([qemu, '-machine', 'pc', '-cpu', 'pentium', '-m', '64', '-bios', image, '-display', 'none',
             '-serial', 'none', '-monitor', 'none', '-no-reboot', '-no-shutdown',
             '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'], leaf, 'free-qemu', 133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        run([sys.executable, '-B', REPO/'verif/qemu-trace/gen_trace.py', '--qemu', qemu,
             '--system', '--x87', '--image', image, '--image-mode', 'bios', '--cpu', 'pentium',
             '--out', leaf/'golden.vtrace', '--max-insn', '2500', '--port', str(port)], leaf, 'golden')
        gold = tracefmt.read_trace(str(leaf/'golden.vtrace'))
        assert 100 < len(gold.records) < 2500 and int(gold.records[-1]['eax'], 0) & 255 == 0x42
        return case, leaf, image, symbols, gold

    def measure(job):
        prepared, name, latency = job
        case, leaf, image, symbols, gold = prepared
        modes = {}
        for mode in ('cycle-func', 'cycle'):
            stem = f'{name}-l{latency}-{mode}'
            path = leaf/(stem+'.vtrace')
            text = run([models[name], '+ven_fp_mem_queue_log', '+ven_faultlog', '--system', '--cosim',
                        '--x87', '--'+mode, '--l1-axi', '--image', image, '--out', path,
                        '--max-insn', '2500', '--max-cycles', '3000000', '--quiesce', '200000'],
                       leaf, stem, 133, latency)
            trace = tracefmt.read_trace(str(path))
            assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records]
            assert [r['n'] for r in trace.records] == list(range(len(trace.records)))
            assert not re.search(r'%Error|%Fatal|CPU HUNG|UNIMPLEMENTED|tb: FAIL', text)
            check_faultlog.check_counts(check_faultlog.read_counts(
                (leaf/(stem+'.stdout')).read_text().splitlines()), {(14, 0): 1} if args.fault else {})
            footer = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                                r'after (\d+) retired in (\d+) clocks$', text, re.M)
            assert len(footer) == 1 and int(footer[0][0]) == len(trace.records)
            queued = [int(owners) for pc, owners in re.findall(r'\[FP-MEM-QUEUE\] ACCEPT pc=([0-9a-f]+) owners=(\d+)', text)
                      if int(pc, 16) == symbols['source_op'] and int(owners) > 0]
            overlap = [int(pc, 16) for pc, owners in re.findall(r'\[FP-MEM-QUEUE\] INTEGER pc=([0-9a-f]+) owners=(\d+)', text)
                       if int(owners) >= 2 and symbols['integer_begin'] <= int(pc, 16) < symbols['integer_end']]
            modes[mode] = dict(trace=trace, clocks=int(footer[0][1]), queued=len(queued), overlap=len(overlap))
            if mode == 'cycle-func':
                with (leaf/(stem+'-diff.log')).open('x') as log:
                    assert compare_complete(gold, trace, log) == 0, (case, name, latency, 'complete QEMU diff')
        assert all(modes['cycle'][k] == modes['cycle-func'][k] for k in ('clocks', 'queued', 'overlap'))
        actual = modes['cycle']
        rows = actual['trace'].records
        hits = [i for i, r in enumerate(rows) if int(r['pc'], 0) == symbols['source_op' if args.fault else 'hot_loop']]
        assert len(hits) == (10 if args.fault else 16)
        if args.fault:
            assert len([r for r in rows if int(r['pc'], 0) == symbols['pf_handler']]) == 1
        assert any(r.get('pipe') == 'V' and r.get('paired') and int(r['pc'], 0) == symbols['pair_v'] for r in rows)
        return dict(case=case, model=name, latency=latency, records=len(rows), full_qemu_diff=True,
                    queued=actual['queued'], integer_overlap=actual['overlap'], total_clocks=actual['clocks'],
                    warm_clocks=[] if args.fault else [rows[b]['cyc']-rows[a]['cyc'] for a,b in zip(hits[4:-1], hits[5:])])

    cases = [(k, d, r, o) for k in range(8) for d in (0, 1) for r in ((0,) if args.smoke else (0, 1))
             for o in ((0,) if args.smoke else (0, 29))]
    if args.fault:
        cases = [(k, 0, 0, split) for k in range(3) for split in (0, 1)]
    result = dict(passed=False, measurements=[], errors=[], gameplay_ipc=None, standard_suite=False,
                  fixture='fault' if args.fault else 'overlap',
                  case_fields=['kind','unused','unused','split'] if args.fault else ['kind','drain','reloc','data_offset'])
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            prepared = list(pool.map(prepare, cases))
        jobs = [(case, name, latency) for case in prepared for name in models for latency in (0, 7)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
            futures = [pool.submit(measure, job) for job in jobs]
            for future in concurrent.futures.as_completed(futures):
                try:
                    result['measurements'].append(future.result())
                except Exception as exc:
                    result['errors'].append(dict(error=repr(exc), traceback=traceback.format_exc()))
        assert len(result['measurements']) == len(jobs) and not result['errors']
        indexed = {(tuple(r['case']), r['model'], r['latency']): r for r in result['measurements']}
        for row in result['measurements']:
            if row['model'] == 'control' or row['case'][1]:
                assert row['queued'] == 0 and row['integer_overlap'] == 0, ('negative control queued', row)
        gains = []
        for case in ([] if args.fault else cases):
            for latency in (0, 7):
                a, b = [indexed[case, name, latency] for name in ('control', 'candidate')]
                assert b['total_clocks'] <= a['total_clocks'], ('whole-program regression', case, latency, a, b)
                assert sum(b['warm_clocks']) <= sum(a['warm_clocks']), ('steady regression', case, latency)
                if case[1]:
                    assert a['total_clocks'] == b['total_clocks'] and a['warm_clocks'] == b['warm_clocks']
                gains.append(dict(case=case, latency=latency, control=sum(a['warm_clocks']),
                                  candidate=sum(b['warm_clocks']), fraction=1-sum(b['warm_clocks'])/sum(a['warm_clocks'])))
        for kind in range(3 if args.fault else 8):
            assert any(r['case'][0] == kind and r['queued'] and (args.fault or r['integer_overlap']) for r in result['measurements'])
        if not args.fault:
            assert any(g['fraction'] > 0 for g in gains)
        result.update(passed=True, gains=gains)
    except Exception as exc:
        result['errors'].append(dict(error=repr(exc), traceback=traceback.format_exc()))
    finally:
        result['inputs_unchanged'] = all(sha(p) == h for p,h in pins.items())
        result['passed'] &= result['inputs_unchanged']
        save(args.out/'result.json', result)
    print(json.dumps(dict(passed=result['passed'], measurements=len(result['measurements']),
                         errors=len(result['errors']), first_error=result['errors'][:1],
                         inputs_unchanged=result['inputs_unchanged'], gameplay_ipc=None), indent=2), flush=True)
    assert result['passed']


if __name__ == '__main__':
    main()
