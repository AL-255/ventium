"""Run the real unified gate with the explicit reference; retain a red verdict.

No RTL rebuild/override, mask change, timing-band waiver, or standard-suite
claim. The supplied core must have a closed, source-pinned private build.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

import qualified_profile as profile

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO/'verif/diff'))
import tracefmt


def dump(path, value):
    with path.open('x') as f:
        json.dump(value, f, indent=2)


def sample_children(targets, samples):
    """Observe real native-child CPU affinity, not an outer unit property."""
    for proc in Path('/proc').iterdir():
        if not proc.name.isdecimal():
            continue
        try:
            exe = (proc/'exe').resolve(strict=True)
            if exe not in targets or exe.name in samples:
                continue
            argv = (proc/'cmdline').read_bytes().decode().rstrip('\0').split('\0')
            # Distinguish this gate from an unrelated invocation of the model.
            if not any(str(targets[exe]) in arg for arg in argv):
                continue
            affinity = sorted(os.sched_getaffinity(int(proc.name)))
            samples[exe.name] = dict(pid=int(proc.name), exe=str(exe), argv=argv,
                affinity=affinity, cgroup=(proc/'cgroup').read_text())
        except (OSError, UnicodeError):
            continue


def analyze(work, prior):
    funcs = []
    for result in sorted(work.glob('*.func.result')):
        row = result.read_text().strip().split('|')
        trace = tracefmt.read_trace(str(work/(row[1]+'.func_rtl.vtrace')))
        log = (work/(row[1]+'.func_rtl.log')).read_text()
        pairs = re.search(r'^\s*(\d+)\s+PAIRED\s+\(U \+ V retired\)', log, re.M)
        totals = re.findall(r'retires\s+(\d+)\s+\(U=(\d+)\s+pairedV=(\d+)\)',log)
        profile.require(len(totals)==1, 'missing/ambiguous retire counters: '+row[1])
        total, primary, secondary = map(int,totals[0])
        profile.require(primary+secondary==total==len(trace.records), 'retirement accounting: '+row[1])
        funcs.append(dict(name=row[1], verdict=row[3], detail=row[4],
                          records=total, u_retired=primary, v_retired=secondary,
                          fast_issue_pairs=int(pairs[1]) if pairs else 0))
    cycles = []
    for new in sorted(work.glob('*.cycle_rtl.vtrace')):
        old = prior/new.name
        a, b = tracefmt.read_trace(str(old)), tracefmt.read_trace(str(new))
        argv = new.with_suffix('.argv').read_bytes().rstrip(b'\0').decode().split('\0')
        safe = '--cycle' in argv and '--l1-axi' in argv and not any(
            arg.startswith(('--dbg-', '--no-trace', '--cycle-func')) for arg in argv)
        cycles.append(dict(name=new.name, records=len(b.records),
            same_prior_records=a.records==b.records, uv_axi_argv=safe,
            v_retired=sum(r.get('pipe')=='V' for r in b.records),
            old_sha256=profile.sha(old), new_sha256=profile.sha(new)))
    return dict(functional=funcs, cycles=cycles,
        functional_passes=sum(r['verdict']=='PASS' for r in funcs),
        functional_records=sum(r['records'] for r in funcs),
        functional_u_retired=sum(r['u_retired'] for r in funcs),
        functional_v_retired=sum(r['v_retired'] for r in funcs),
        functional_fast_issue_pairs=sum(r['fast_issue_pairs'] for r in funcs),
        cycle_records_unchanged=len(cycles)==20 and all(r['same_prior_records'] for r in cycles),
        cycle_argv_checked=len(cycles)==20 and all(r['uv_axi_argv'] for r in cycles))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core', type=Path, required=True)
    ap.add_argument('--reference', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    core, reference = args.core.resolve(strict=True), args.reference.resolve(strict=True)
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    profile.require(out.is_relative_to(scratch) and not out.exists(), 'need a fresh external run')
    profile.require(Path(os.environ['TMPDIR']).resolve(strict=True)==scratch, 'explicit external TMPDIR required')
    profile.require(os.access(scratch, os.W_OK) and shutil.disk_usage(scratch).free>5*1024**3,
                    'need writable external scratch and >5 GiB free')
    binary = (core/'obj/tb_ventium').resolve(strict=True)
    built = json.loads((core/'build-closed.json').read_text())
    profile.require(built['passed'] and built['pins_unchanged'] and built['native_exit']==0,
                    'core build not qualified')
    profile.require(profile.sha(binary)==built['binary_sha256'], 'core binary drift')
    qemu = profile.select(reference)
    build_start = json.loads((core/'build-started.json').read_text())
    pins = build_start['pins']
    profile.require(all(profile.sha(p)==h for p,h in pins.items()), 'core input drift')
    inputs = [Path(__file__), binary, qemu, core/'build-started.json', core/'build-closed.json',
              reference/'closed.json', reference/'source.json', REPO/'Makefile',
              REPO/'verif/verify.sh', REPO/'verif/m4_metrics.py', REPO/'verif/m5_metrics.py',
              REPO/'build/p5trace.so',
              REPO/'ventium-refs/07-p5-emulation-harness/tools/isa_verify.py']
    for folder, patterns in (
        ('verif/qemu-trace', ('*.py',)), ('verif/diff', ('*.py',)),
        ('verif/lib', ('*.py','*.sh')), ('verif/tests', ('*.s','*.S','*.json','*.py')),
        ('verif/issue_uv', ('run-issue-uv-gate.sh','tb_issue_uv.sv')),
        ('tools', ('build_scope.sh','verilator_serial.sh'))):
        for pattern in patterns:
            inputs.extend((REPO/folder).rglob(pattern))
    for path in inputs:
        pins[str(path)] = profile.sha(path)
    env = {k:v for k,v in os.environ.items() if not k.startswith(
        ('VEN_', 'VENTIUM_', 'VTM_', 'TB_', 'AXI_', 'VERIFY_', 'M5_', 'MAKE'))
        and k not in ('QEMU','P5TRACE','MEMORY_ADC','DUAL_READ_ALU','LOAD_USE_FORWARD')}
    settings = dict(TMPDIR=str(scratch), PYTHONDONTWRITEBYTECODE='1',
        VTM_QEMU_PROFILE_BUILD=str(reference),
        VENTIUM_VERILATOR_BIN='/tools/verilator/v5.046/bin/verilator',
        TB_BIN=str(binary), TB_EXTRA_FLAGS='--cycle-func --l1-axi',
        TB_CYCLE_EXTRA_FLAGS='--l1-axi', AXI_RLAT='7', AXI_WLAT='7',
        VERIFY_WORKDIR=str(out/'work'), VERIFY_CACHE_DIR=str(out/'cache'),
        VERIFY_JOBS='1', PORTBASE='39700')
    env.update(settings)
    command = [str(REPO/'tools/build_scope.sh'), '--', 'taskset', '-c', '0-3',
               'timeout', '--signal=TERM', '--kill-after=15s', '600s', 'make', 'verify']
    out.mkdir()
    dump(out/'started.json',dict(command=command,pins=pins,environment=settings,
        core_build=str(core),reference_profile=profile.PROFILE,
        invocation=os.environ.get('INVOCATION_ID'), core_definitions=build_start['definitions']))
    begin = time.monotonic()
    samples, details, errors = {}, {}, []
    rc = None
    with (out/'native.log').open('x') as log:
        child = subprocess.Popen(command, env=env, cwd=REPO, stdout=log,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while child.poll() is None:
                sample_children({binary:out, qemu:out}, samples)
                if time.monotonic()-begin>660 or shutil.disk_usage(scratch).free<4*1024**3:
                    raise RuntimeError('time/disk safety boundary reached')
                time.sleep(1)
            rc = child.wait()
            details = analyze(out/'work', core/'generic-work')
            profile.select(reference)  # Recheck all 11,132 native source files.
        except Exception as error:
            errors.append(str(error))
        finally:
            if child.poll() is None:
                os.killpg(child.pid,signal.SIGTERM)
                try:
                    child.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid,signal.SIGKILL)
                    child.wait()
            if rc is None:
                rc=child.returncode
    unchanged = all(Path(p).is_file() and profile.sha(p)==h for p,h in pins.items())
    confined = set(samples)=={binary.name,qemu.name} and all(
        set(v['affinity'])<=set(range(4)) for v in samples.values())
    dump(out/'closed.json',dict(native_exit=rc,gate_passed=rc==0 and not errors,
        pins_unchanged=unchanged,errors=errors,seconds=time.monotonic()-begin,
        native_samples=samples,native_affinity_checked=confined,**details,
        standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,
        masks_or_bands_changed=False,reference_profile=profile.PROFILE))
    return 0 if rc==0 and unchanged and confined and not errors else 1


if __name__=='__main__':
    raise SystemExit(main())
