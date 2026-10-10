#!/usr/bin/env python3
"""Whole-core FP high-word transport: cold paged A/B, full x87 QEMU and cycle records."""
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
import traceback

REPO = Path('/home/yukidama/github/ventium')
HERE = Path(__file__).resolve().parent
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


def grade_fp_native(trace, stdout, stderr, return_code, expected_exit, max_insn):
    """Full x87 variant of the native closure grader; no trace rewriting."""
    if return_code != expected_exit:
        raise ValueError(f"actual native exit {return_code} != manifest {expected_exit}")
    if (trace.hdr.get("vtrace") != tracefmt.VERSION or trace.hdr.get("producer") != "rtl"
            or trace.mode != "func" or trace.hdr.get("sys") is not True or not trace.x87):
        raise ValueError("wrong native functional system trace header")
    rows = trace.records
    if not rows or len(rows) >= max_insn:
        raise ValueError("empty or instruction-cap-exhausted native trace")
    required = tracefmt.func_compare_keys(True, True)
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or type(row.get("n")) is not int or row["n"] != index:
            raise ValueError("noncontiguous/unfiltered native trace")
        if any(key not in row for key in required):
            raise ValueError("missing architectural native field")
        for key in required + [key for key in tracefmt.SYS_SEG_HIDDEN if key in row]:
            value = row[key]
            if type(value) not in (str, int):
                raise ValueError(f"invalid native field type: {key}")
            parsed = tracefmt.parse_hex(value)
            if not 0 <= parsed < 1 << tracefmt._WIDTH[key]:
                raise ValueError(f"out-of-range native field: {key}")
    for name, log in (("stdout", stdout), ("stderr", stderr)):
        if len(log.encode("utf-8")) > native.LOG_LIMIT or (log and not log.endswith("\n")):
            raise ValueError(f"truncated/oversized native {name}")
    if not stderr or native.FATAL.search(stdout) or native.FATAL.search(stderr):
        raise ValueError("empty/fatal native diagnostics")
    # Streams are closed before inspection; never splice buffered live streams.
    lines = stdout.splitlines() + stderr.splitlines()
    stops = [line for line in lines if line.startswith("tb: stop:")]
    stop = (re.fullmatch(r"tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) "
                         r"after (\d+) retired in (\d+) clocks", stops[0])
            if len(stops) == 1 else None)
    footers = [re.fullmatch(r"tb: retired (\d+) instructions in (\d+) clocks "
                            r"\(bus: \d+ reads, \d+ writes\)", line)
               for line in lines if line.startswith("tb: retired")]
    if (not stop or int(stop[1]) != len(rows) or int(stop[2]) <= 0 or len(footers) != 1
            or not footers[0] or footers[0].groups() != stop.groups()):
        raise ValueError("missing/duplicate/mismatching normal debug-exit/retirement footer")
    io_lines = [line for line in lines if line.startswith("tb: M7.3b")]
    io = (re.fullmatch(r"tb: M7.3b win95 co-sim: (\d+) IN reads serviced "
                       r"\((\d+) dev_in available, cursor at (\d+)\), (\d+) OUT writes consumed, "
                       r"(\d+) port/size desync\(s\), isa-debug-exit reached", io_lines[0])
          if len(io_lines) == 1 else None)
    # Plain --cosim enables real I/O requests, not device-input replay. Legitimate
    # test I/O counts may vary; do not hardcode one OUT/zero IN for all fixtures.
    if not io or int(io[2]) or int(io[3]) or int(io[4]) < 1 or int(io[5]):
        raise ValueError("missing/duplicate/replayed/desynchronized real-I/O footer")
    return dict(records=len(rows), clocks=int(stop[2]), in_reads=int(io[1]), out_writes=int(io[4]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--control', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--offset', type=int, action='append')
    parser.add_argument('--kind', type=int, action='append')
    parser.add_argument('--operand-offset', type=int, choices=(0,1,24,25,29,4093))
    parser.add_argument('--workers', type=int, default=32, choices=range(1, 33))
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    assert args.out.resolve().is_relative_to(scratch)
    assert shutil.disk_usage(scratch).free > 1024**3
    offsets = sorted(set(args.offset if args.offset is not None else range(32)))
    assert offsets and all(0 <= x < 32 for x in offsets)
    kinds = sorted(set(args.kind if args.kind is not None else range(6)))
    assert kinds and all(0 <= x < 6 for x in kinds)
    if args.operand_offset is not None:
        assert kinds == [1], 'operand-boundary fixture requires the scalar load mix'
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
    added = {'VEN_FP_LOAD64_PAYLOAD_SELECT'}
    assert {'VEN_FP_PIPE_PAYLOAD_SELECT', 'VEN_SRT_PAYLOAD_SELECT', 'VEN_FP_LOAD_PAYLOAD_SELECT', 'VEN_FP_LOAD64'} <= profiles['control']
    assert {'VEN_P54_PREFIX_EX_CHAIN','VEN_P54_PREFIX_EX_SYSTEM'} <= profiles['control']
    assert not added & profiles['control']
    assert profiles['candidate'] == profiles['control'] | added
    source = HERE/('fp-payload-system.S' if args.operand_offset is None else 'fp-load-payload-system.S')
    shutil.copyfile(source, args.out/'fixture-source.S')
    shutil.copyfile(Path(__file__), args.out/'runner-source.py')
    linker = REPO/'verif/sys/tests/ppage/ppage.ld'
    qemu = REPO/'ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386'
    for p in (Path(__file__), source, linker, qemu, REPO/'verif/qemu-trace/gen_trace.py',
              REPO/'verif/diff/tracefmt.py', REPO/'verif/diff/compare.py',
              REPO/'verif/sys/run-native-system.py', REPO/'verif/sys/check_faultlog.py'):
        pins[str(p)] = sha(p)
    save(args.out/'started.json', dict(pins=pins, offsets=offsets, kinds=kinds, models={k:str(v) for k,v in models.items()},
        invocation=os.environ.get('INVOCATION_ID'), unix=time.time(), workers=args.workers,
        operand_offset=args.operand_offset))
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
            f'-DKIND={kind}', f'-DRELOC={reloc}', f'-DOFFSET={offset}',
            *([] if args.operand_offset is None else [f'-DSOURCE_OFFSET={args.operand_offset}']),
            '-c', source, '-o', obj])
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
            '--system', '--x87', '--image', image, '--image-mode', 'bios', '--cpu', 'pentium',
            '--out', golden_path, '--max-insn', '2000', '--port', str(port)])
        gold = tracefmt.read_trace(str(golden_path))
        assert gold.mode == 'func' and gold.sys and gold.x87 and 100 < len(gold.records) < 2000
        assert int(gold.records[-1]['eax'], 0) & 255 == 0x42
        assert all(all(k in r for k in tracefmt.SYS_CR) for r in gold.records)
        measures = []
        cycle_observations = {}
        accept_observations = {}
        for latency in (0, 7):
            for name, model in models.items():
                traces, stops, captures, wide_counts = {}, {}, [], []
                for mode in ('cycle-func', 'cycle'):
                    stem = f'{name}-lat{latency}-{mode}'
                    path = leaf/(stem+'.vtrace')
                    out, err = run(leaf, stem, [model, '--system', '--cosim', '--x87', '--'+mode, '--l1-axi',
                        '--image', image, '--out', path, '--max-insn', '2000', '--max-cycles', '1000000',
                        '--quiesce', '4096', '+ven_faultlog', '+ven_fpdirectlog', '+ven_fpload64log'],
                        133, latency)
                    if args.operand_offset is not None:
                        wide = re.findall(r'^\[FPLOAD64\] complete resident operands=(\d+)$', out+'\n'+err, re.M)
                        assert len(wide) == 1, 'missing actual wide-response witness'
                        count = int(wide[0])
                        assert count >= 15 if args.operand_offset in (0,1,24) else count == 0, (case, stem, count)
                        wide_counts.append(count)
                    trace = tracefmt.read_trace(str(path))
                    traces[mode] = trace.records
                    if mode == 'cycle-func':
                        assert trace.mode == 'func' and trace.x87 and trace.sys
                    else:
                        # Cycle records contain retirement timing, not GPR/x87
                        # state; the separate cycle-func run owns that check.
                        assert trace.mode == 'cycle' and not trace.x87 and not trace.sys
                    assert [r['n'] for r in trace.records] == list(range(len(gold.records)))
                    assert [r['pc'] for r in trace.records] == [r['pc'] for r in gold.records]
                    check_faultlog.check_counts(check_faultlog.read_counts(out.splitlines()), {})
                    assert not native.FATAL.search(out) and not native.FATAL.search(err)
                    footer = re.findall(r'^tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) '
                                        r'after (\d+) retired in (\d+) clocks$', err, re.M)
                    assert len(footer) == 1 and int(footer[0][0]) == len(trace.records)
                    stops[mode] = int(footer[0][1])
                    if mode == 'cycle-func':
                        grade_fp_native(trace, out, err, 133, 133, 2000)
                        with (leaf/(stem+'-diff.log')).open('x') as log:
                            assert compare.compare_func(gold, trace, True, 0xffffffff, False, 20,
                                                        log, sys_both=True) == 0, (case, stem, 'QEMU diff')
                    else:
                        captures = re.findall(r'\[FPEARLY\] ACCEPT cyc=(\d+) pc=([0-9a-f]+) immediate=([01])',out)
                        accept_observations[(latency,name)] = captures
                assert stops['cycle'] == stops['cycle-func'], 'observation changed clocks'
                rows = traces['cycle']
                cycle_observations[(latency,name)] = rows
                hits = [i for i,r in enumerate(rows) if int(r['pc'],0) == symbols['hot_load']]
                assert len(hits) == 16
                pairs = [r for r in rows if int(r['pc'],0) == symbols['pair_v'] and
                         r.get('pipe') == 'V' and r.get('paired')]
                assert len(pairs) == 1, (case, name, 'missing actual U/V pair')
                assert captures, 'missing actual early FP command acceptance'
                intervals=[rows[i]['cyc']-rows[i-1]['cyc'] for i in hits]
                assert min(intervals) > 0
                measures.append(dict(case=case, model=name, latency=latency, records=len(rows),
                    clocks=stops['cycle'], paired_v=len(pairs),
                    early_accepts=len(captures),
                    operand_offset=args.operand_offset, wide_counts=wide_counts,
                    fp_intervals=intervals,
                    warm_loops=[rows[b]['cyc']-rows[a]['cyc'] for a,b in zip(hits[2:-1],hits[3:])]))
        for latency in (0,7):
            assert accept_observations[(latency,'control')] == accept_observations[(latency,'candidate')], 'FP acceptance events differ'
            assert cycle_observations[(latency,'control')] == cycle_observations[(latency,'candidate')], 'entire cycle record lists differ'
            if args.operand_offset is not None:
                values = [m['wide_counts'] for m in measures if m['latency'] == latency]
                assert len(values) == 2 and values[0] == values[1], 'wide-response counts differ'
        save(leaf/'closed.json', dict(passed=True, complete_cycle_streams_identical=True, measurements=measures, image_sha256=sha(image)))
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
                except Exception as exc:
                    result['errors'].append(dict(case=futures[future], error=repr(exc),
                                                 traceback=traceback.format_exc()))
        assert len(result['measurements']) == len(cases)*len(models)*2 and not result['errors']
        bycase={(tuple(r['case']),r['latency'],r['model']):r for r in result['measurements']}
        deltas=[]
        for case in cases:
            for latency in (0,7):
                a=bycase[(case,latency,'control')];b=bycase[(case,latency,'candidate')]
                deltas.append(dict(case=case,latency=latency,saved_clocks=a['clocks']-b['clocks']))
        result['deltas']=deltas
        assert all(r['saved_clocks']==0 for r in deltas)
        assert all(r['saved_clocks']>=0 for r in deltas)
        assert all(r['early_accepts'] > 0 for r in result['measurements'])
        result['passed'] = True
    except Exception as exc: result['errors'].append(dict(error=repr(exc)))
    finally:
        result.update(pins_unchanged=all(sha(p)==h for p,h in pins.items()),
                      all_children_reaped=True, seconds=time.monotonic()-started)
        result['passed'] &= result['pins_unchanged']
        save(args.out/'closed.json', result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('measurements','deltas')},indent=2),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())

