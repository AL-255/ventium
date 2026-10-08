#!/usr/bin/env python3
"""32 full-core UV+fast shift/Jcc cases against pinned Pentium QEMU.

Requires a prebuilt, source-pinned candidate; never rebuilds or changes its mode.
--cycle and --cycle-func both enable cycle_mode=1. Every subject must retire U
with its following Jcc in V on the same cycle; architectural fallback is FAIL.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'verif/diff'))
import tracefmt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tb', type=Path, required=True)
    args = parser.parse_args()
    scratch = Path('/home/yukidama/external/tmp')
    if subprocess.check_output(['findmnt', '-T', str(scratch), '-no', 'FSTYPE'], text=True).strip() != 'ext4':
        parser.error('external scratch is not mounted ext4')
    if shutil.disk_usage(scratch).free < 128 * 1024**2:
        parser.error('less than 128 MiB free')
    tb = args.tb.resolve(strict=True)
    build_record = tb.parent / 'Vventium_top__verFiles.dat'
    command_line = next(line[2:] for line in build_record.read_text().splitlines() if line.startswith('C '))
    build_args = shlex.split(shlex.split(command_line)[0])
    definitions = {a.removeprefix('+define+') for a in build_args if a.startswith('+define+')}
    required = {'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC', 'VEN_SYS_FASTLOAD_FLAT',
                'VEN_SYS_FASTLOAD_BOUNDED', 'VEN_SYS_FASTSTORE_FLAT', 'VEN_L1_AXI',
                'VEN_FP_PIPE', 'VEN_FP_PIPE2', 'VEN_FAST_BYTE_SHIFT', 'VEN_FAST_ROR_IMM',
                'VEN_P54_PREFIX66_REG'}
    if not required <= definitions:
        parser.error(f'prebuilt model is missing required fast profile definitions: {sorted(required-definitions)}')
    out = Path(tempfile.mkdtemp(prefix='ventium-uv-shift-branch.', dir=scratch))
    print(f'UV branch evidence: {out}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('VEN_', 'TB_', 'AXI_'))}
    env.update(TMPDIR=str(out), PYTHONDONTWRITEBYTECODE='1', QEMU_CPU='pentium', QEMU_RESERVED_VA='256M')
    qemu = ROOT / 'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386'
    src = ROOT / 'verif/issue_uv/t_uv_shift_branch.S'
    inputs = [tb, build_record, qemu, src, Path(__file__).resolve(), ROOT / 'verif/qemu-trace/gen_trace.py',
              ROOT / 'verif/tests/elf2flat.py', ROOT / 'verif/diff/tracefmt.py']
    def hashes():
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    pins = hashes()
    (out / 'inputs.json').write_text(json.dumps(pins, indent=2))
    (out / 'mode-contract.json').write_text(json.dumps(dict(definitions=sorted(definitions),
        cycle_mode=1, debug_step=False, debug_breakpoint=False, require_same_cycle_uv=True), indent=2))

    def command(argv, stem, timeout=30, overrides=None):
        (out / (stem + '.command.json')).write_text(json.dumps(argv, indent=2))
        with (out / (stem + '.log')).open('xb') as log:
            proc = subprocess.Popen(argv, env=dict(env, **(overrides or {})), stdout=log,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            try:
                rc = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                # The golden producer owns a QEMU child. Reap the whole owned
                # process group rather than leaving an orphan on timeout.
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                rc = 124
        (out / (stem + '.exit')).write_text(str(rc) + '\n')
        if rc:
            raise RuntimeError(f'{stem}: native exit {rc}')

    def prepare(case):
        stem = f'case{case}'
        elf, flat = out / (stem + '.elf'), out / (stem + '.flat')
        command(['gcc', '-m32', '-nostdlib', '-static', '-Wl,--build-id=none',
                 '-Wl,-Ttext=0x08048000', f'-DCASE={case}', str(src), '-o', str(elf)], stem + '-build')
        symbols = {p[2]: int(p[0], 16) for line in subprocess.check_output(['nm', '-n', str(elf)], text=True).splitlines()
                   if len(p := line.split()) == 3}
        (out / (stem + '.symbols.json')).write_text(json.dumps(symbols, indent=2))
        command([sys.executable, '-B', str(ROOT / 'verif/tests/elf2flat.py'), str(elf),
                 '--out', str(flat), '--base', '0x08048000'], stem + '-flat')
        command([str(qemu), '-cpu', 'pentium', str(elf)], stem + '-qemu-exit')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        golden = out / (stem + '-qemu.vtrace')
        command([sys.executable, '-B', str(ROOT / 'verif/qemu-trace/gen_trace.py'), '--qemu', str(qemu),
                 '--elf', str(elf), '--out', str(golden), '--max-insn', '100', '--port', str(port)], stem + '-qemu-trace')
        gold = tracefmt.read_trace(str(golden)).records
        assert gold and int(gold[-1]['ebp'], 0) == 0x42 and int(gold[-1]['ebx'], 0) == 0
        assert all(int(r['pc'], 0) != symbols['uv_fail'] for r in gold)
        return symbols, gold

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        fixtures = list(pool.map(prepare, range(8)))

    def run(job):
        case, latency, mode = job
        symbols, gold = fixtures[case]
        stem = f'case{case}-lat{latency}-{mode}'
        target = out / (stem + '.vtrace')
        row = dict(case=case, latency=latency, mode=mode, cycle_mode=1, pass_=False)
        try:
            command([str(tb), '--' + mode, '--l1-axi', '--image', str(out / f'case{case}.flat'),
                     '--load', '0x08048000', '--entry', '0x08048000', '--init-esp', gold[0]['esp'],
                     '--out', str(target), '--max-insn', '100', '--max-cycles', '500000', '--quiesce', '200000'],
                    stem, overrides=dict(AXI_RLAT=str(latency), AXI_WLAT=str(latency)))
            rows = tracefmt.read_trace(str(target)).records
            assert len(rows) == len(gold) + 1, ('retire length', len(rows), len(gold))
            assert [r['pc'] for r in rows[:-1]] == [r['pc'] for r in gold], 'wrong architectural path'
            assert int(rows[-1]['pc'], 0) == int(gold[-1]['pc'], 0) + 5, 'terminal INT80 missing'
            rows = rows[:-1]  # QEMU omits the exiting syscall; RTL observes it.
            assert [r['pc'] for r in rows] == [r['pc'] for r in gold], 'wrong architectural path'
            i = next(i for i, r in enumerate(rows) if int(r['pc'], 0) == symbols['uv_subject'])
            assert int(rows[i+1]['pc'], 0) == symbols['uv_branch']
            if mode == 'cycle':
                # Producer C marks the younger V record as paired; U's marker
                # is false even when it leads a pair. Require actual U/V slots
                # and equal retire cycles instead of misinterpreting that bit.
                assert rows[i+1]['paired'] is True, 'subject pair was suppressed'
                assert rows[i]['pipe'] == 'U' and rows[i+1]['pipe'] == 'V', 'not U then V'
                assert rows[i]['cyc'] == rows[i+1]['cyc'], 'not same-cycle dual issue'
                row['paired_cycle'] = rows[i]['cyc']
            else:
                # The branch writes no architectural registers/flags, so both
                # subject records must equal QEMU without a pair-boundary mask.
                for n in (i, i+1, len(rows)-1):
                    for key in tracefmt.GPR_KEYS + tracefmt.SEG_KEYS + ['eflags']:
                        assert rows[n][key] == gold[n][key], (n, key, gold[n][key], rows[n][key])
            row['pass_'] = True
        except (AssertionError, RuntimeError, StopIteration) as exc:
            row['error'] = str(exc)
        (out / (stem + '.result.json')).write_text(json.dumps(row, indent=2))
        print(json.dumps(row), flush=True)
        return row

    jobs = [(case, latency, mode) for case in range(8) for latency in (0, 7) for mode in ('cycle', 'cycle-func')]
    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
        results = list(pool.map(run, jobs))
    unchanged = hashes() == pins
    passed = unchanged and all(r['pass_'] for r in results)
    (out / 'results.json').write_text(json.dumps(dict(pass_=passed, inputs_unchanged=unchanged,
        cases=results, gameplay_ipc=None, standard_suite=False, fpga_acceptance=False), indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
