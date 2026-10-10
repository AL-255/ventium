#!/usr/bin/env python3
"""Paged UV-fast coherent-write-window A/B, complete QEMU records."""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path[:0] = [str(REPO/'verif/diff'), str(REPO/'verif/sys')]
import check_faultlog
import compare
import tracefmt
spec = importlib.util.spec_from_file_location('native', REPO/'verif/sys/run-native-system.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def save(p, value):
    with p.open('x') as f:
        json.dump(value, f, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--offset', type=int, action='append')
    parser.add_argument('--kind', type=int, action='append')
    parser.add_argument('--workers', type=int, default=4, choices=range(1, 5))
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    assert shutil.disk_usage(scratch).free > 1024**3
    offsets = sorted(set(args.offset if args.offset is not None else range(32)))
    assert offsets and all(0 <= x < 32 for x in offsets)
    kinds = sorted(set(args.kind if args.kind is not None else range(4)))
    assert kinds and all(0 <= x < 4 for x in kinds)
    args.out.mkdir()
    models = {'control': args.control.resolve(strict=True), 'candidate': args.candidate.resolve(strict=True)}
    profiles, pins = {}, {}
    for name, model in models.items():
        stamp = model.parent/'Vventium_top__verFiles.dat'
        command = next(line for line in stamp.read_text().splitlines() if line.startswith('C '))
        defs = set(re.findall(r'\+define\+(\w+)', command))
        assert ' --assert ' in command
        assert {'VEN_L1_AXI', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_FE_PIPE',
                'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTSTORE_FLAT', 'VEN_IC_BRAM',
                'VEN_RAW_V_READ_PRIME', 'VEN_PIPE_MEM_CHAIN', 'VEN_PIPE_REG_LOAD_PRIME'} <= defs
        assert not {'VEN_SYS_FASTPATH_ALL', 'VTM_NO_DPI', 'SYNTHESIS', 'VEN_UOPCACHE'} & defs
        profiles[name] = defs
        pins.update({str(p): sha(p) for p in (model, stamp)})
    flag = 'VEN_L1D_WINDOW_WRITE_UPDATE'
    assert flag not in profiles['control']
    assert profiles['candidate'] == profiles['control'] | {flag}
    source = HERE/'window_update_core.S'
    shutil.copyfile(source, args.out/'fixture-source.S')
    shutil.copyfile(Path(__file__), args.out/'runner-source.py')
    linker = REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__), source, linker, qemu, REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py', REPO/'verif/diff/compare.py',
              REPO/'verif/sys/run-native-system.py', REPO/'verif/sys/check_faultlog.py'):
        pins[str(p)] = sha(p)
    save(args.out/'started.json', dict(pins=pins, offsets=offsets, kinds=kinds, models={k:str(v) for k,v in models.items()},
        invocation=os.environ.get('INVOCATION_ID'), unix=time.time(), workers=args.workers))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'VTM_', 'TB_', 'QEMU_', 'AXI_'))}
    env.update(TMPDIR=str(args.out), PYTHONDONTWRITEBYTECODE='1')

    def run(leaf, name, command, expected=0, latency=0):
        command = ['timeout', '--signal=TERM', '--kill-after=3s', '45s', *map(str, command)]
        save(leaf/(name+'.command.json'), command)
        with (leaf/(name+'.stdout')).open('x') as out, (leaf/(name+'.stderr')).open('x') as err:
            rc = subprocess.run(command, env=dict(env, AXI_RLAT=str(latency), AXI_WLAT=str(latency)),
                                stdout=out, stderr=err).returncode
        save(leaf/(name+'.exit.json'), dict(native_exit=rc))
        assert rc == expected, (leaf.name, name, rc, expected)
        return (leaf/(name+'.stdout')).read_text(), (leaf/(name+'.stderr')).read_text()

    def check(case):
        kind, reloc, offset = case
        leaf = args.out/f'k{kind}-r{reloc}-o{offset}'
        leaf.mkdir()
        obj, elf, image = [leaf/('fixture.'+ext) for ext in ('o', 'elf', 'bin')]
        run(leaf, 'assemble', ['gcc', '-m32', '-nostdlib', '-ffreestanding', '-fno-pie', '-fno-pic',
            f'-DKIND={kind}', f'-DRELOC={reloc}', f'-DOFFSET={offset}', '-c', source, '-o', obj])
        run(leaf, 'link', ['gcc', '-m32', '-static', '-no-pie', '-nostdlib',
            '-Wl,-T,'+str(linker), '-Wl,--build-id=none', obj, '-o', elf])
        run(leaf, 'binary', ['objcopy', '-O', 'binary', '--gap-fill', '0', '--pad-to', '0x100000', elf, image])
        symbols = {p[2]: int(p[0], 16) for line in subprocess.check_output(['nm', '-n', elf], text=True).splitlines()
                   if len(p := line.split()) == 3 and p[0] != 'U'}
        assert image.stat().st_size == 65536 and symbols['hot_u'] % 32 == offset
        run(leaf, 'free-qemu', [qemu, '-machine', 'pc', '-cpu', 'pentium', '-m', '64', '-bios', image,
            '-display', 'none', '-serial', 'none', '-monitor', 'none', '-no-reboot', '-no-shutdown',
            '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'], 133)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        golden_path = leaf/'golden.vtrace'
        run(leaf, 'golden', [sys.executable, '-B', REPO/'verif/qemu-trace/gen_trace.py', '--qemu', qemu,
            '--system', '--image', image, '--image-mode', 'bios', '--cpu', 'pentium',
            '--out', golden_path, '--max-insn', '2000', '--port', str(port)])
        gold = tracefmt.read_trace(str(golden_path))
        assert gold.mode == 'func' and gold.sys and 100 < len(gold.records) < 2000
        assert int(gold.records[-1]['eax'], 0) & 255 == 0x42
        assert all(all(k in r for k in tracefmt.SYS_CR) for r in gold.records)
        measures = []
        for latency in (0, 7):
            for name, model in models.items():
                traces, stops, captures = {}, {}, []
                for mode in ('cycle-func', 'cycle'):
                    stem = f'{name}-lat{latency}-{mode}'
                    path = leaf/(stem+'.vtrace')
                    out, err = run(leaf, stem, [model, '--system', '--cosim', '--'+mode, '--l1-axi',
                        '--image', image, '--out', path, '--max-insn', '2000', '--max-cycles', '1000000',
                        '--quiesce', '4096', '+ven_faultlog', '+ven_fetchdbg', '+ven_fetchdbg_max=10000'],
                        133, latency)
                    trace = tracefmt.read_trace(str(path))
                    traces[mode] = trace.records
                    assert [r['n'] for r in trace.records] == list(range(len(gold.records)))
                    assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records]
                    check_faultlog.check_counts(check_faultlog.read_counts(out.splitlines()), {})
                    assert not native.FATAL.search(out) and not native.FATAL.search(err)
                    footer = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                                        r'after (\d+) retired in (\d+) clocks$', err, re.M)
                    assert len(footer) == 1 and int(footer[0][0]) == len(trace.records)
                    stops[mode] = int(footer[0][1])
                    if mode == 'cycle-func':
                        native.grade_native(trace, out, err, 133, 133, 2000)
                        with (leaf/(stem+'-diff.log')).open('x') as log:
                            assert compare.compare_func(gold, trace, False, 0xffffffff, False, 20,
                                                        log, sys_both=True) == 0, (case, stem, 'QEMU diff')
                    else:
                        captures = [dict(eip=int(pc,16),next=int(nxt,16),addr=int(addr,16),v=int(v))
                            for pc,nxt,addr,v in re.findall(r'\[FETCHDBG:RAWBRANCHPRIME\] '
                            r'eip=([0-9a-f]+) next=([0-9a-f]+) addr=([0-9a-f]+) v=(\d+)', out)]
                assert stops['cycle'] == stops['cycle-func'], 'observation changed clocks'
                rows = traces['cycle']
                hits = [i for i,r in enumerate(rows) if int(r['pc'],0) == symbols['hot_load']]
                assert len(hits) == 16
                pairs = [r for r in rows if int(r['pc'],0) == symbols['pair_v'] and
                         r.get('pipe') == 'V' and r.get('paired')]
                assert len(pairs) == 1, (case, name, 'missing actual U/V pair')
                measures.append(dict(case=case, model=name, latency=latency, records=len(rows),
                    clocks=stops['cycle'], paired_v=len(pairs),
                    stores_paired=sum(int(r['pc'],0)==symbols['second_store'] and r.get('pipe')=='V'
                                      and bool(r.get('paired')) for r in rows),
                    load_intervals=[rows[i]['cyc']-rows[i-1]['cyc'] for i in hits],
                    warm_loops=[rows[b]['cyc']-rows[a]['cyc'] for a,b in zip(hits[2:-1],hits[3:])]))
        save(leaf/'closed.json', dict(passed=True, measurements=measures, image_sha256=sha(image)))
        return measures

    cases = [(k,r,o) for k in kinds for r in (0,1) for o in offsets]
    result = dict(passed=False, errors=[], measurements=[], gameplay_ipc=None, standard_suite=False,
                  all_children_reaped=False)
    started = time.monotonic()
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
            futures = {pool.submit(check,c):c for c in cases}
            for future in concurrent.futures.as_completed(futures):
                try: result['measurements'].extend(future.result())
                except Exception as exc: result['errors'].append(dict(case=futures[future],error=repr(exc)))
        assert len(result['measurements']) == len(cases)*len(models)*2 and not result['errors']
        bycase={(tuple(r['case']),r['latency'],r['model']):r for r in result['measurements']}
        deltas=[]
        for case in cases:
            for latency in (0,7):
                a=bycase[(case,latency,'control')];b=bycase[(case,latency,'candidate')]
                deltas.append(dict(case=case,latency=latency,saved_clocks=a['clocks']-b['clocks']))
        result['deltas']=deltas
        assert any(r['saved_clocks']>0 for r in deltas if r['case'][0]==0)
        assert all(r['saved_clocks']>=0 for r in deltas)
        if 3 in kinds:assert any(r['stores_paired'] for r in result['measurements'] if r['case'][0]==3)
        result['passed'] = True
    except Exception as exc: result['errors'].append(dict(error=repr(exc)))
    finally:
        result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                      all_children_reaped=True, seconds=time.monotonic()-started)
        result['passed'] &= result['pins_unchanged']
        save(args.out/'closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k!='measurements'},indent=2),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
