#!/usr/bin/env python3
"""Guarded same-model gameplay capture plus recorder OFF/ON replay check.

Run through tools/build_scope.sh; uses private disk copies, never edits the input
bundle. The old frozen executable is kept alongside the host-only relink.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile


def sha(path):
    with open(path, 'rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('bundle', type=Path)
    p.add_argument('objdir', type=Path)
    p.add_argument('--start', type=int, required=True)
    p.add_argument('--cycles', type=int, default=1000000)
    a = p.parse_args()
    if not 0 < a.cycles <= 1000000:
        p.error('cycles must be 1..1000000')
    repo = Path(__file__).resolve().parents[1]
    bundle, obj = a.bundle.resolve(), a.objdir.resolve()
    subprocess.run(['python3', str(repo/'tools/checkpoint_bundle.py'), str(bundle)], check=True, pass_fds=(9,))
    work = Path(tempfile.mkdtemp(prefix='ventium-state-delta.', dir=os.environ['TMPDIR']))
    print('Artifacts:', work, flush=True)
    shutil.copy2(obj/'ao486sim_ven', work/'profiler')
    for name in ['ven_state_fields.inc', 'ven_state_fields.audit.json', 'Vsystem__verFiles.dat']:
        shutil.copy2(obj/name, work/name)
    hashes = {str(p): sha(p) for p in [bundle/'gameplay.snap', bundle/'guest.vhd', bundle/'ao486sim_ven', work/'profiler', obj/'Vsystem__ALL.a']}
    (work/'provenance.json').write_text(json.dumps(hashes, indent=2)+'\n')
    env = dict(os.environ, FPGA_DDR='2', AO486_RTC_EPOCH='1789257600', AO486_BIOS_DIR=str(bundle/'rom'))
    def run(name, cycles, enabled, binary):
        out = work/name
        out.mkdir()
        shutil.copy2(bundle/'guest.vhd', out/'guest.vhd')
        # Archived bundles can be read-only. Only this fresh private disk is
        # opened read/write by IDE; preserve the source and other file modes.
        disk = out/'guest.vhd'
        disk.chmod(stat.S_IMODE(disk.stat().st_mode) | stat.S_IWUSR)
        cmd = [str(binary), '--restore', str(bundle/'gameplay.snap'), '--snapshot-v3',
               '--rate', '45000000', '--rate-rtc', '45000000', '--rate-vga', '90000000',
               '--mem', '32', '--ide', str(out/'guest.vhd'), '--cycles', str(a.start+cycles+10000),
               '--save-at', str(a.start+cycles), '--save-stop', '--save-file', str(out/'end.snap'),
               '--ven-perf-every', str(cycles)]
        if enabled:
            cmd += ['--ven-delta-out', str(out/'state.delta.gz'), '--ven-delta-start', str(a.start), '--ven-delta-cycles', str(cycles)]
        (out/'invocation.json').write_text(json.dumps(dict(argv=cmd, cwd=str(repo/'ao486-sim'),
            env={k:env[k] for k in ['FPGA_DDR','AO486_RTC_EPOCH','AO486_BIOS_DIR']}), indent=2)+'\n')
        with open(out/'run.log', 'wb') as log:
            subprocess.run(cmd, cwd=repo/'ao486-sim', env=env, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=3600, pass_fds=(9,))
        print(name, 'OK', flush=True)
        return out
    pilot = run('pilot', 1000, True, work/'profiler')
    subprocess.run(['python3', str(repo/'tools/state_delta_read.py'), str(pilot/'state.delta.gz')], check=True, pass_fds=(9,))
    # OFF/ON of the relinked observer alone cannot detect an unrelated host
    # behavior change during that relink. Also replay the frozen cold-boot
    # executable from this exact bundle, before spending time on the full trace.
    reference = run('reference', 1000, False, bundle/'ao486sim_ven')
    relink_results = {}
    for name in ['end.snap', 'guest.vhd']:
        lhs, rhs = sha(reference/name), sha(pilot/name)
        relink_results[name] = dict(reference=lhs, profiler=rhs, identical=lhs == rhs)
    (work/'host_relink_check.json').write_text(json.dumps(relink_results, indent=2)+'\n')
    if not all(result['identical'] for result in relink_results.values()):
        raise RuntimeError('host-only profiler differs from the frozen source executable')
    print('STATE-DELTA-HOST-REPLAY-OK: frozen executable and profiler match', flush=True)
    baseline = run('off', a.cycles, False, work/'profiler')
    trace = run('on', a.cycles, True, work/'profiler')
    results = {}
    for name in ['end.snap', 'guest.vhd']:
        lhs, rhs = sha(baseline/name), sha(trace/name)
        results[name] = dict(off=lhs, on=rhs, identical=lhs == rhs)
        if lhs != rhs:
            raise RuntimeError(f'recorder altered execution: {name}')
    # Native same-model cold-derived checkpoint: no architectural state patching.
    (work/'observer_check.json').write_text(json.dumps(results, indent=2)+'\n')
    subprocess.run(['python3', str(repo/'tools/checkpoint_bundle.py'), str(bundle)], check=True, pass_fds=(9,))
    print('STATE-DELTA-OBSERVER-OK: native final snapshot and disk identical', flush=True)
    print('Trace:', trace/'state.delta.gz', flush=True)


if __name__ == '__main__':
    main()
