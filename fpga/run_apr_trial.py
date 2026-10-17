"""Bounded, serial APR experiment. Never synthesizes or deploys a bitstream."""
import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

REPO = Path(__file__).resolve().parent.parent
SCRATCH = Path('/home/yukidama/external/tmp')
BASE = SCRATCH/'ventium-fprem-sequence.iSZ9BAj4/programmable-clock-power-repair-r5'
CHECKPOINT_SHA = 'b38e8bd49d8327eb6497146016e252703f9e90235957e903ec85f932fec41d17'
STRATEGIES = ('postroute-aggressive', 'postroute-replication', 'replace-netdelay')
GIB = 1024**3
SCOPE = 'ventium-vivado.scope'


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def host():
    return {r.split()[0].rstrip(':'): int(r.split()[1])*1024
            for r in Path('/proc/meminfo').read_text().splitlines()
            if r.startswith(('MemAvailable:', 'SwapFree:'))}


def scope():
    text = subprocess.check_output(['systemctl', '--user', 'show', SCOPE,
        '-p', 'ActiveState', '-p', 'InvocationID', '-p', 'ControlGroup',
        '-p', 'MemoryMax', '-p', 'MemorySwapMax', '-p', 'TasksMax'], text=True, timeout=5)
    return dict(r.split('=', 1) for r in text.splitlines() if '=' in r)


def validate_timing(text):
    rows = list(csv.DictReader(text.splitlines(), delimiter='\t'))
    expected = {('mmcm_clk', 'mmcm_clk'), ('clk_pl_0', 'clk_pl_0'),
                ('mmcm_clk', 'clk_pl_0'), ('clk_pl_0', 'mmcm_clk')}
    if len(rows) != 4 or {(r['from_clock'], r['to_clock']) for r in rows} != expected:
        raise ValueError('missing/duplicate timing domains')
    for row in rows:
        for key in ('setup_ns', 'hold_ns', 'period_ns', 'requirement_ns'):
            row[key] = float(row[key])
            if not math.isfinite(row[key]): raise ValueError('nonfinite timing')
        period = 25 if row['to_clock'] == 'mmcm_clk' else 10
        if abs(row['period_ns']-period) > .001: raise ValueError('clock changed')
        same = row['from_clock'] == row['to_clock']
        if same:
            if abs(row['requirement_ns']-period) > .001 or row['exception'].strip().lower() not in ('', 'none'):
                raise ValueError('not an ordinary same-domain full-cycle path')
            budget = period-row['setup_ns']
            mhz = float(row['conditional_mhz'])
            if budget <= 0 or not math.isfinite(mhz) or abs(mhz-1000/budget) > .000001:
                raise ValueError('invalid frequency estimate')
            row['conditional_mhz'] = mhz
        elif row['conditional_mhz'] != 'NA': raise ValueError('cross-domain frequency invented')
    return rows


def validate_reports(build):
    route = (build/'after-route-status.rpt').read_text()
    counts = {}
    for name in ('routable nets', 'fully routed nets', 'nets with routing errors'):
        found = re.findall(r'# of '+re.escape(name)+r'\.+\s*:\s*(\d+)\s*:', route)
        if len(found) != 1: raise ValueError('missing/ambiguous route count: '+name)
        counts[name] = int(found[0])
    if not counts['routable nets'] == counts['fully routed nets'] > 200000 or counts['nets with routing errors']:
        raise ValueError('incomplete/erroneous routing')
    drc = (build/'drc.rpt').read_text()
    if not re.search(r'Design State\s*:\s*Fully Routed', drc): raise ValueError('not fully routed DRC')
    if re.search(r'\|\s*(?:Error|Critical Warning)\s*\|', drc): raise ValueError('DRC error/critical warning')
    before = validate_timing((build/'before-timing.tsv').read_text())
    after = validate_timing((build/'after-timing.tsv').read_text())
    if abs(before[0]['setup_ns']+9.841) > .002: raise ValueError('baseline timing drift')
    return dict(route_counts=counts, before=before, after=after,
                hold_nonnegative=all(r['hold_ns'] >= 0 for r in after),
                other_setup_nonnegative=all(r['setup_ns'] >= 0 for r in after[1:]))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--strategy', choices=STRATEGIES, required=True)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    assert __debug__ and os.environ['TMPDIR'] == str(SCRATCH)
    assert os.environ.get('INVOCATION_ID'), 'use a retained systemd user owner'
    dest = args.output.resolve()
    assert dest.is_relative_to(SCRATCH.resolve()) and dest != SCRATCH.resolve() and not dest.exists()
    assert dest.parent.is_dir() and dest.parent.stat().st_dev == SCRATCH.stat().st_dev != REPO.stat().st_dev
    assert scope()['ActiveState'] in ('inactive', 'failed')
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    checkpoint = BASE/'build/routed.dcp'
    prior = json.loads((BASE/'closed.json').read_text())
    assert prior['passed'] and prior['products']['routed.dcp'] == sha(checkpoint) == CHECKPOINT_SHA
    assert host()['MemAvailable'] > 14*GIB and host()['SwapFree'] > 8*GIB
    assert shutil.disk_usage(SCRATCH).free > 5*GIB
    script = REPO/'fpga/apr_trial.tcl'
    pins = {str(p): sha(p) for p in (checkpoint, BASE/'closed.json', script, Path(__file__),
        REPO/'fpga/run_vivado_exclusive.sh', REPO/'tools/build_scope.sh')}
    dest.mkdir(); (dest/'tool-tmp').mkdir()
    def save(name, data):
        with (dest/name).open('x') as stream: json.dump(data, stream, indent=2)
    limit = 13800 if args.strategy == 'replace-netdelay' else 3600
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'VENTIUM_', 'TB_', 'AXI_'))}
    env.update(TMPDIR=str(dest/'tool-tmp'), VIVADO_BIN='/tools/Xilinx/2025.2/Vivado/bin/vivado',
        VENTIUM_VIVADO_MEMORY_MAX='12G', VENTIUM_VIVADO_MEMORY_SWAP_MAX='4G',
        VENTIUM_VIVADO_LOCK_DIR=str(SCRATCH))
    command = ['timeout', '--signal=TERM', '--kill-after=60s', f'{limit}s',
        str(REPO/'fpga/run_vivado_exclusive.sh'), '-mode', 'batch', '-notrace',
        '-log', str(dest/'native.log'), '-journal', str(dest/'native.jou'),
        '-source', str(script), '-tclargs', str(checkpoint), CHECKPOINT_SHA, args.strategy, str(dest/'build')]
    save('started.json', dict(strategy=args.strategy, pins=pins, command=command,
        invocation=os.environ['INVOCATION_ID'], host=host(), disk_free=shutil.disk_usage(dest).free,
        memory_max=12*GIB, swap_max=4*GIB, whole_run_limit_seconds=limit,
        rtl_changed=False, synthesis=False, deployment=False))
    interrupted = []
    signal.signal(signal.SIGTERM, lambda s,f: interrupted.append(s))
    signal.signal(signal.SIGINT, lambda s,f: interrupted.append(s))
    owner = reason = failure = None
    peak_ram = peak_swap = 0
    start = time.monotonic()
    with (dest/'guard.log').open('x') as log, (dest/'watch.jsonl').open('x') as watch:
        process = subprocess.Popen(command, cwd=dest, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                current = scope()
                if current['ActiveState'] == 'active':
                    group = Path('/sys/fs/cgroup'+current['ControlGroup'])
                    if not group.exists(): continue
                    if owner is None:
                        members = (group/'cgroup.procs').read_text().split()
                        for pid in members:
                            try: cmd = Path('/proc', pid, 'cmdline').read_bytes()
                            except FileNotFoundError: continue
                            if str(dest/'native.log').encode() in cmd:
                                assert current['MemoryMax'] == str(12*GIB)
                                assert current['MemorySwapMax'] == str(4*GIB) and current['TasksMax'] == '48'
                                owner = current; break
                    if owner:
                        assert current['InvocationID'] == owner['InvocationID']
                        ram = int((group/'memory.current').read_text())
                        swap = int((group/'memory.swap.current').read_text())
                        events = dict(line.split() for line in (group/'memory.events').read_text().splitlines())
                        peak_ram, peak_swap = max(peak_ram, ram), max(peak_swap, swap)
                        resources, free = host(), shutil.disk_usage(dest).free
                        if free < 4*GIB: reason = '4 GiB disk reserve'
                        elif min(resources.values()) < 2*GIB: reason = '2 GiB host RAM/swap reserve'
                        elif ram+swap > 15*GIB: reason = 'combined memory early stop'
                        elif int(events['oom']) or int(events['oom_kill']): reason = 'scope OOM'
                        watch.write(json.dumps(dict(elapsed=time.monotonic()-start, memory=ram,
                            swap=swap, events=events, host=resources, disk_free=free, reason=reason))+'\n')
                        watch.flush()
                if interrupted: reason = 'controller signal'
                if time.monotonic()-start > limit: reason = 'wall deadline'
                if reason: break
                time.sleep(5)
        except BaseException as error: failure = repr(error)
        finally:
            if process.poll() is None:
                current = scope()
                if current['ActiveState'] == 'active':
                    assert owner and current['InvocationID'] == owner['InvocationID']
                    subprocess.run(['systemctl', '--user', 'kill', '--kill-whom=all', '--signal=TERM', SCOPE], check=True)
                process.terminate()
                try: process.wait(timeout=40)
                except subprocess.TimeoutExpired:
                    current = scope()
                    if current['ActiveState'] == 'active':
                        assert owner and current['InvocationID'] == owner['InvocationID']
                        subprocess.run(['systemctl', '--user', 'kill', '--kill-whom=all', '--signal=KILL', SCOPE], check=True)
                    process.kill()
            code = process.wait(timeout=15)
    elapsed = time.monotonic()-start
    unchanged = all(sha(p) == h for p,h in pins.items())
    checked = None
    try:
        assert code == 0 and not reason and not failure and unchanged and owner and elapsed < limit
        assert 'APR-TRIAL-COMPLETE strategy='+args.strategy in (dest/'native.log').read_text()
        assert scope()['ActiveState'] in ('inactive', 'failed')
        checked = validate_reports(dest/'build')
        assert (dest/'build/result.dcp').stat().st_size > 50_000_000
    except Exception as error: failure = (failure+'; ' if failure else '')+'audit: '+repr(error)
    result = dict(completed=checked is not None and not failure, native_exit=code, reason=reason,
        failure=failure, strategy=args.strategy, elapsed=elapsed, inputs_unchanged=unchanged,
        owner=owner, peak_ram=peak_ram, peak_swap=peak_swap, measurements=checked,
        products={p.name:sha(p) for p in (dest/'build').iterdir() if p.is_file()} if (dest/'build').exists() else {},
        timing_signoff=False, hardware_acceptance=False, gameplay_ipc=None)
    save('closed.json', result)
    print(json.dumps(result, indent=2), flush=True)
    if not result['completed']: raise SystemExit(1)


if __name__ == '__main__': main()
