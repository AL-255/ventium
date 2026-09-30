#!/usr/bin/env python3
"""Prebuilt-binary PREFIX66 line-placement matrix, at most 32 bounded workers.

Run inside tools/build_scope.sh's reviewed ipc_parallel32 scope. Staging the
QEMU and RTL work avoids 32 shell+timeout+Python+QEMU trees under the task cap.
Every fixture uses the same authoritative architectural/spacing checker as
the single-case shell runner. No FPGA compilation, snapshots, or score claim.
"""
import argparse
import concurrent.futures
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / 'verif/issue_uv'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tb-bin', required=True, type=Path)
parser.add_argument('--out', type=Path)
parser.add_argument('--jobs', type=int, default=32, choices=range(1, 33))
parser.add_argument('--port-base', type=int, default=42000)
parser.add_argument('--case', type=int, choices=range(12))
parser.add_argument('--pad', type=int, choices=range(32))
args = parser.parse_args()
if (os.environ.get('VENTIUM_BUILD_SCOPE_PROFILE') != 'ipc_parallel32' or
        os.environ.get('VENTIUM_BUILD_SCOPE_UNIT') != 'ventium-ipc-parallel32'):
    raise SystemExit('matrix requires the reviewed ipc_parallel32 unit/profile')
binary = args.tb_bin.resolve(strict=True)
out = args.out or Path(tempfile.mkdtemp(prefix='ventium-prefix66-matrix-', dir='/tmp'))
out.mkdir(parents=True, exist_ok=True)
# The verified guard's lock is FD 9. Preserve it only for this containment
# check; ordinary subprocess default close_fds would falsely discard proof.
subprocess.run([str(ROOT/'tools/build_scope.sh'), '--is-active'], check=True, pass_fds=(9,))
qemu = ROOT/'ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386'
cases = [args.case] if args.case is not None else range(12)
pads = [args.pad] if args.pad is not None else range(32)
jobs = [dict(case=c, pad=p, index=i, out=str(out/f'case{c:02d}-pad{p:02d}'))
        for i, (c, p) in enumerate((c, p) for c in cases for p in pads)]
if args.port_base < 1024 or args.port_base + len(jobs) > 65535:
    raise SystemExit('port range must fit distinct nonprivileged TCP ports')
started = time.monotonic()
deadline = started + 540
# Pinned QEMU has both a main and a call_rcu thread. The Python worker pool
# itself has 33 tasks at jobs=32; 32 simultaneous golden trees would exceed
# TasksMax128 (33 + 32 * (gen_trace + QEMU main + QEMU RCU) = 129). Keep the
# requested 32-worker pool, but cap this one stage to 24 active golden trees.
golden_slots = threading.Semaphore(min(args.jobs, 24))

def command(argv, folder, log, timeout=30, env=None):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise subprocess.TimeoutExpired(argv, 540)
    timeout = min(timeout, remaining)
    with (folder/log).open('w') as output:
        proc = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=output,
                                stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # gen_trace owns a QEMU grandchild. Killing only its Python PID
            # would orphan that guest until outer-scope teardown. This process
            # group contains only the current generated fixture's descendants.
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
            raise
        if code:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            raise subprocess.CalledProcessError(code, argv)

def stage(job, name):
    folder = Path(job['out'])
    folder.mkdir(exist_ok=True)
    case, pad = job['case'], job['pad']
    try:
        if name == 'assemble':
            command(['as', '--32', '--defsym', f'CASE={case}', '--defsym', f'LOOP_PAD={pad}',
                     str(HERE/'t_prefix66_reg.s'), '-o', str(folder/'test.o')], folder, 'as.log')
            ld = ['ld', '-m', 'elf_i386']
            if case == 10:
                ld += ['-T', str(HERE/'prefix66_rwx.ld')]
            command(ld + ['-Ttext', '0x08048000', str(folder/'test.o'), '-o', str(folder/'test.elf')],
                    folder, 'ld.log')
            with (folder/'test.sym').open('w') as sym:
                subprocess.run(['nm', '-n', str(folder/'test.elf')], stdout=sym, check=True)
            command(['python3', str(ROOT/'verif/tests/elf2flat.py'), str(folder/'test.elf'),
                     '--out', str(folder/'test.flat'), '--base', '0x08048000'], folder, 'flat.log')
        elif name == 'golden':
            env = os.environ.copy()
            env.update(QEMU_RESERVED_VA='256M', QEMU_CPU='pentium')
            with golden_slots:
                command(['prlimit', '--as=1073741824', '--', 'python3',
                         str(ROOT/'verif/qemu-trace/gen_trace.py'), '--qemu', str(qemu),
                         '--elf', str(folder/'test.elf'), '--out', str(folder/'test.qemu.vtrace'),
                         '--max-insn', '12000', '--port', str(args.port_base+job['index'])],
                        folder, 'qemu.log', timeout=90, env=env)
        elif name in ('cycle', 'cycle-func'):
            with (folder/'test.qemu.vtrace').open() as gold:
                next(gold)
                esp = json.loads(next(gold))['esp']
            command(['prlimit', '--as=1073741824', '--', str(binary), f'--{name}',
                     '--image', str(folder/'test.flat'), '--load', '0x08048000',
                     '--entry', '0x08048000', '--init-esp', esp,
                     '--out', str(folder/f'test.{name}.vtrace'), '--max-insn', '12000',
                     '--max-cycles', '200000', '--quiesce', '1000'], folder, f'{name}.log')
        elif name == 'check':
            command(['python3', str(HERE/'check-p54-prefix66-reg.py'), str(folder), str(case)],
                    folder, 'check.log')
            # Preserve exact evidence without keeping GBs of repetitive JSON.
            # This compresses files, not measured core behavior or trace data.
            for trace in folder.glob('*.vtrace'):
                with trace.open('rb') as source, gzip.GzipFile(str(trace)+'.gz', 'wb', mtime=0) as packed:
                    shutil.copyfileobj(source, packed)
                trace.unlink()
        return job
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError, ValueError) as error:
        job['failed_stage'] = name
        job['error'] = str(error)
        print(json.dumps(job), flush=True)
        return job

with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
    for name in ('assemble', 'golden', 'cycle', 'cycle-func', 'check'):
        active = [job for job in jobs if 'failed_stage' not in job]
        list(pool.map(lambda job: stage(job, name), active))
        failed = sum('failed_stage' in job for job in jobs)
        print(f'PREFIX66 matrix {name}: {len(jobs)-failed}/{len(jobs)} clear', flush=True)
summary = dict(binary=str(binary), binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
               seconds=round(time.monotonic()-started, 3), workers=args.jobs,
               active_golden_limit=min(args.jobs, 24),
               placement_note='case8 fixes PC=0x0804fffe; its pads repeat one placement',
               passed=sum('failed_stage' not in job for job in jobs), total=len(jobs), jobs=jobs)
(out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
print(f'Artifacts: {out}', flush=True)
raise SystemExit(int(summary['passed'] != summary['total']))
