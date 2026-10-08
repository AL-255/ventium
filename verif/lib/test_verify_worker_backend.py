#!/usr/bin/env python3
"""Exercise the real CYCLE worker with a prebuilt UV-fast user-mode model.

This checks option transport, backend activity and actual V retirement, NOT
P5 timing bands, functional equivalence or standard-suite acceptance. No RTL
build, fake testbench, comparator override or golden substitution is performed.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parents[2]
SCRATCH = Path('/home/yukidama/external/tmp')
REQUIRED = {'VEN_L1_AXI', 'VEN_L1D_PERF', 'VEN_SYS_FASTPATH',
            'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_FLAT',
            'VEN_SYS_FASTLOAD_BOUNDED', 'VEN_SYS_FASTSTORE_FLAT'}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run_case(case, output, base, worker, source):
    name, flags, latency, reject = case
    work = output / name
    work.mkdir()
    env = dict(base, WORKDIR=str(work), TB_CYCLE_EXTRA_FLAGS=flags,
               AXI_RLAT=str(latency), AXI_WLAT=str(latency))
    argv = ['bash', str(worker), 'cycle', 'mb_dmiss', str(source),
            '0x08048000', '0x08048000', '9000', '0', '0']
    (work / 'command.json').write_text(json.dumps(argv, indent=2) + '\n')
    row = dict(case=name, passed=False, requested_flags=flags, latency=latency)
    try:
        with (work / 'worker.log').open('xb') as log:
            rc = subprocess.run(argv, env=env, stdout=log,
                                stderr=subprocess.STDOUT, timeout=60).returncode
        result = (work / 'mb_dmiss.cycle.result').read_text().strip()
        row.update(worker_exit=rc, result=result)
        argvfile = work / 'mb_dmiss.cycle_rtl.argv'
        if reject:
            row['passed'] = (rc == 0 and result.startswith('CYCLE|mb_dmiss|CACHE|0|')
                             and 'invalid CYCLE trace/mode flag' in result
                             and not argvfile.exists()
                             and not (work / 'mb_dmiss.cycle_rtl.vtrace').exists())
        else:
            command_bytes = argvfile.read_bytes()
            assert command_bytes.endswith(b'\0'), 'incomplete argv receipt'
            command = [part.decode() for part in command_bytes.split(b'\0')[:-1]]
            log = (work / 'mb_dmiss.cycle_rtl.log').read_text()
            match = re.search(r'\[L1DPERF\] fill cycles=\d+ backing-wait=\d+ backing-ack=(\d+)', log)
            assert match, 'missing actual L1 backend counter'
            acks = int(match[1])
            with (work / 'mb_dmiss.cycle_rtl.vtrace').open() as stream:
                header = json.loads(next(stream))
                records = [json.loads(line) for line in stream]
            assert header['mode'] == 'cycle'
            assert all(r['n'] == n for n, r in enumerate(records))
            pairs = [i for i, r in enumerate(records)
                     if r.get('pipe') == 'V' and r.get('paired')]
            assert all(i > 0 and records[i-1]['pipe'] == 'U'
                       and records[i-1]['cyc'] == records[i]['cyc'] for i in pairs)
            is_axi = name != 'direct'
            row.update(argv=command, backing_acks=acks, paired_v=len(pairs),
                       records=len(records), last_cycle=records[-1]['cyc'],
                       pc_sequence_sha256=hashlib.sha256(
                           '\n'.join(r['pc'] for r in records).encode()).hexdigest())
            row['passed'] = (rc == 0 and result.startswith('CYCLE|mb_dmiss|CACHE|1|')
                             and '--cycle-func' not in command
                             and command.count('--cycle') == 1
                             and ('--l1-axi' in command) == is_axi
                             and acks == (16400 if is_axi else 0)
                             and len(pairs) == 4101 and len(records) == 8204)
    except (AssertionError, OSError, ValueError, KeyError, StopIteration,
            subprocess.TimeoutExpired) as exc:
        row['error'] = str(exc)
    (work / 'result.json').write_text(json.dumps(row, indent=2) + '\n')
    print(json.dumps(row), flush=True)
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tb', type=Path, required=True,
                        help='prebuilt tb_ventium, with adjacent Verilator command receipt')
    args = parser.parse_args()
    tb = args.tb.resolve(strict=True)
    stamp = tb.parent / 'Vventium_top__verFiles.dat'
    commands = [line for line in stamp.read_text().splitlines() if line.startswith('C ')]
    if len(commands) != 1:
        parser.error('expected one Verilator command receipt')
    defines = sorted(set(re.findall(r'\+define\+([A-Z][A-Z0-9_]*)', commands[0])))
    if not REQUIRED.issubset(defines) or {'VEN_KV260_SOC', 'SYNTHESIS', 'VTM_NO_DPI'} & set(defines):
        parser.error('need a UV-fast AXI/perf user-mode model, not a SoC or assertion-disabled build')
    scratch = SCRATCH.resolve(strict=True)
    if (not os.access(scratch, os.W_OK) or
            shutil.disk_usage(scratch).free < 128 * 1024 * 1024):
        parser.error('external scratch needs at least 128 MiB free')
    output = Path(tempfile.mkdtemp(prefix='ventium-worker-backend.', dir=scratch))
    (output / 'cache').mkdir()
    ref = REPO / 'ventium-refs/07-p5-emulation-harness'
    worker = REPO / 'verif/lib/verify_worker.sh'
    source = REPO / 'verif/tests/mb_dmiss/mb_dmiss.s'
    base = {k: v for k, v in os.environ.items()
            if not k.startswith(('VEN_', 'TB_', 'AXI_', 'QEMU_'))}
    base.update(ROOT=str(REPO), QEMU=str(ref / 'build/qemu/build/qemu-i386'),
                GEN_TRACE=str(REPO / 'verif/qemu-trace/gen_trace.py'),
                COMPARE=str(REPO / 'verif/diff/compare.py'),
                ELF2FLAT=str(REPO / 'verif/tests/elf2flat.py'),
                ISA_VERIFY=str(ref / 'tools/isa_verify.py'),
                P5TRACE=str(REPO / 'build/p5trace.so'), TB_BIN=str(tb),
                M5_METRICS=str(REPO / 'verif/m5_metrics.py'),
                PYTHON=sys.executable, CC='gcc',
                CFLAGS_BASE='-m32 -march=pentium -nostdlib -static -Wl,--build-id=none',
                CACHE_DIR=str(output / 'cache'), PORTBASE='30000', M5_TOL_PCT='10',
                TMPDIR=str(output), PYTHONDONTWRITEBYTECODE='1', KCLASS='CACHE',
                # Deliberately incompatible with CYCLE format: must not leak.
                TB_EXTRA_FLAGS='--cycle-func --l1-axi')
    inputs = [worker, source, tb, stamp, Path(__file__).resolve(),
              *(Path(base[k]) for k in ('QEMU', 'P5TRACE', 'COMPARE', 'ELF2FLAT', 'ISA_VERIFY'))]
    pins = {str(path): digest(path) for path in inputs}
    (output / 'inputs.json').write_text(json.dumps(pins, indent=2) + '\n')
    (output / 'defines.json').write_text(json.dumps(defines, indent=2) + '\n')
    print(f'Evidence: {output}', flush=True)
    cases = [('direct', '', 0, False),
             ('axi0', '--l1-axi --quiesce 200000', 0, False),
             ('axi7', '--l1-axi --quiesce 200000', 7, False),
             ('bad-format', '--cycle-func', 0, True),
             ('bad-discard', '--no-trace', 0, True),
             ('bad-step', '--dbg-step', 0, True),
             ('bad-bp', '--dbg-bp 0x08048000', 0, True)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(cases)) as pool:
        futures = [pool.submit(run_case, case, output, base, worker, source) for case in cases]
        rows = [future.result() for future in futures]
    stable = pins == {str(path): digest(path) for path in inputs}
    runs = rows[:3]
    ordered = (all(row['passed'] for row in runs)
               and runs[0]['last_cycle'] < runs[1]['last_cycle'] < runs[2]['last_cycle']
               and len({row['pc_sequence_sha256'] for row in runs}) == 1)
    passed = stable and ordered and all(row['passed'] for row in rows)
    result = dict(passed=passed, cases=rows, inputs_unchanged=stable,
                  cycle_band_acceptance=False, functional_acceptance=False,
                  standard_suite=False, gameplay_ipc=None)
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('WORKER-BACKEND-OPTIONS-' + ('OK' if passed else 'FAIL'), flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
