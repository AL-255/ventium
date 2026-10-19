"""Resource-bounded, source-only full synthesis/APR; no prior DCP inputs.

Every invocation gets a separate frozen source copy and a new Vivado project.
The CPU/profile is the deployed image's source, not the dirty checkout. Only
the repaired full-width programmable clock replaces the original clock files.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

from run_apr_trial import GIB, REPO, SCRATCH, SCOPE, host, scope, sha, validate_timing
from prepare_programmable_clock_repair import adapt
from audit_fresh_strategy import audit_synth, audit_impl

ANCESTOR = SCRATCH/'ventium-fprem-sequence.iSZ9BAj4/programmable-clock-r3'
PREPARED_SHA = '5308f8044f35b387e833e1b62a52ec7605bb3a5e157096d9327b638d4b659a54'
REPAIRED = SCRATCH/'ventium-fprem-sequence.iSZ9BAj4/programmable-clock-power-repair-r5/source'
CLOCK_HASHES = {
    'ven_pll_ctrl.sv': '02f1cd73c2d8a13181dc605a89850e0513c84a9fb2c510784ab5b56e830a1237',
    'ven_programmable_clock.v': 'cea6e80e4ca1240bfb2b1d3920c869458e21e30f19aa96fe77743be86109d2e9',
}
STRATEGIES = ('performance-netdelay', 'routability-spread', 'performance-retime-bounded',
              'performance-bounded')
# Fixed reviewed envelopes, not arbitrary numeric overrides. The larger one is
# serial-only and remains inside build_scope.sh's existing 20 GiB RAM ceiling.
MEMORY_PROFILES = {'standard16': (16, 6), 'serial20': (20, 6)}
WHOLE_LIMIT, IMPL_LIMIT = 8*3600, 3*3600+50*60


def save(dest, name, value):
    with (dest/name).open('x') as f:
        json.dump(value, f, indent=2)


def source_inventory(root):
    result = {}
    for p in root.rglob('*'):
        if p.is_symlink():
            raise ValueError('source symlink: '+str(p))
        if p.is_file():
            if p.suffix.lower() in ('.dcp', '.bit', '.bin', '.xsa', '.xpr', '.edf', '.edn', '.ngc'):
                raise ValueError('non-source build product in freeze: '+str(p))
            result[str(p.relative_to(root))] = sha(p)
    return result


def prepare(dest):
    assert sha(ANCESTOR/'prepared.json') == PREPARED_SHA
    prior = json.loads((ANCESTOR/'prepared.json').read_text())
    before = source_inventory(ANCESTOR/'source')
    assert before == prior['source_pins'], 'source closure changed'
    assert len(prior['hardware_defines']) == 159
    assert prior['hardware_defines'] == (ANCESTOR/'source/defines.txt').read_text().splitlines()
    for name, digest in CLOCK_HASHES.items():
        assert sha(REPO/'fpga'/name) == digest
    assert sha(REPAIRED/'ven_pll_ctrl.sv') == CLOCK_HASHES['ven_pll_ctrl.sv']
    # Compare full-build clock RTL to the deployed ECO's exact port adaptation.
    # Only source is inspected; no old checkpoint is read or passed to Vivado.
    assert adapt((REPO/'fpga/ven_programmable_clock.v').read_text()) == (REPAIRED/'ven_programmable_clock.v').read_text()
    dest.mkdir()
    source = dest/'source'
    shutil.copytree(ANCESTOR/'source', source)
    for name in CLOCK_HASHES:
        shutil.copy2(REPO/'fpga'/name, source/'ventium/fpga'/name)
    after = source_inventory(source)
    assert after.keys() == before.keys()
    changed = sorted(n for n in after if before[n] != after[n])
    assert set(changed) <= {'ventium/fpga/'+n for n in CLOCK_HASHES}
    pins = {str(source/n): h for n, h in after.items()}
    # Pin launch dependencies too, including imported helper modules.
    for name in ('run_fresh_strategy.py', 'fresh_strategy.tcl', 'fresh_synth_post.tcl', 'fresh_synth_evidence.tcl',
                 'fresh_route_pre.tcl', 'fresh_reports.tcl', 'fresh_bounded_phys.tcl', 'run_apr_trial.py',
                 'prepare_programmable_clock_repair.py', 'prepare_programmable_clock.py',
                 'audit_clock_reuse.py', 'audit_fresh_strategy.py', 'run_vivado_exclusive.sh'):
        pins[str(REPO/'fpga'/name)] = sha(REPO/'fpga'/name)
    pins[str(REPO/'tools/build_scope.sh')] = sha(REPO/'tools/build_scope.sh')
    save(dest, 'prepared.json', dict(parent_source=str(ANCESTOR/'source'),
        parent_receipt_sha256=PREPARED_SHA, source_pins=after, changed=changed,
        source_identity='deployed CPU/profile plus source-equivalent repaired full-width clock',
        dirty_checkout_cpu_used=False, prior_checkpoint_inputs=[],
        cpu_cache_rtl_byte_identical=True, hardware_defines=prior['hardware_defines'],
        constrained_core_mhz=40, axi_mhz=100, cycle_mode=1,
        hardware_acceptance=False, gameplay_ipc=None))
    return pins


def validate_native_synth(text, strategy, properties, threads=1):
    # Vivado omits default-valued arguments from its generated command. The
    # actual property report, not the spelling of a default, is the authority.
    return audit_synth(text, properties, strategy, threads)['command']


def stage_deadline(text, now):
    rows = [r.split('\t') for r in text.splitlines()]
    starts = [int(t) for name, t in rows if name == 'impl_1']
    if len(starts) > 1:
        raise ValueError('duplicate implementation launch')
    return bool(starts and now-starts[0] >= IMPL_LIMIT)


def task_policy(threads):
    if type(threads) is not int or threads not in (1, 2):
        raise ValueError('unsupported internal thread count')
    return ('serial', 48) if threads == 1 else ('parallel2', 128)


def memory_policy(profile, threads):
    task_policy(threads)
    if not isinstance(profile, str) or profile not in MEMORY_PROFILES:
        raise ValueError('unsupported memory profile')
    if profile == 'serial20' and threads != 1:
        raise ValueError('serial20 requires one internal thread')
    return MEMORY_PROFILES[profile]


def resource_stop(ram, swap, resources, free, events, limit_hit, ram_gib, swap_gib):
    if free < 4*GIB: return '4 GiB disk reserve'
    if min(resources.values()) < 2*GIB: return '2 GiB host RAM/swap reserve'
    if ram+swap > (ram_gib+swap_gib-1)*GIB: return 'combined memory early stop'
    if int(events['oom']) or int(events['oom_kill']): return 'scope OOM'
    if limit_hit: return 'scope task limit'
    return None


def check_scope_limits(current, tasks_max, memory_profile='standard16'):
    if type(tasks_max) is not int or tasks_max not in (48, 128):
        raise ValueError('unsupported task limit')
    ram_gib, swap_gib = memory_policy(memory_profile, 1 if tasks_max == 48 else 2)
    expected = dict(MemoryMax=str(ram_gib*GIB), MemorySwapMax=str(swap_gib*GIB),
                    TasksMax=str(tasks_max))
    if any(current.get(key) != value for key, value in expected.items()):
        raise ValueError('live resource limits differ from launch contract')
    return expected


def task_pressure(current_text, events_text, limit):
    def number(text):
        if not text or not text.isascii() or not text.isdecimal():
            raise ValueError('invalid task counter')
        return int(text)
    current = number(current_text.strip())
    if not 0 <= current <= limit:
        raise ValueError('task count exceeds configured limit')
    events = {}
    for row in events_text.splitlines():
        fields = row.split()
        if len(fields) != 2 or fields[0] in events:
            raise ValueError('invalid/duplicate task event')
        events[fields[0]] = number(fields[1])
    if 'max' not in events:
        raise ValueError('missing task-limit event counter')
    return dict(current=current, events=events, limit_hit=events['max'] != 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--strategy', choices=STRATEGIES, required=True)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--threads', type=int, choices=(1, 2), default=1,
                    help='internal tool threads; always one Vivado family and -jobs 1')
    ap.add_argument('--memory-profile', choices=MEMORY_PROFILES, default='standard16',
                    help='fixed RAM/swap envelope; serial20 requires one internal thread')
    args = ap.parse_args()
    task_profile, tasks_max = task_policy(args.threads)
    ram_gib, swap_gib = memory_policy(args.memory_profile, args.threads)
    assert __debug__ and os.environ['TMPDIR'] == str(SCRATCH)
    assert os.environ.get('INVOCATION_ID'), 'use a retained systemd owner'
    dest = args.output.resolve()
    assert dest.is_relative_to(SCRATCH.resolve()) and dest != SCRATCH.resolve() and not dest.exists()
    assert dest.parent.is_dir() and dest.parent.stat().st_dev == SCRATCH.stat().st_dev != REPO.stat().st_dev
    assert os.access(SCRATCH, os.W_OK)
    assert scope()['ActiveState'] in ('inactive', 'failed')
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    assert host()['MemAvailable'] > (ram_gib+2)*GIB and host()['SwapFree'] > (swap_gib+4)*GIB
    assert shutil.disk_usage(SCRATCH).free > 7*GIB
    pins = prepare(dest)
    (dest/'tool-tmp').mkdir()
    source = dest/'source'
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'VENTIUM_', 'TB_', 'AXI_'))}
    env.update(TMPDIR=str(dest/'tool-tmp'), VIVADO_BIN='/tools/Xilinx/2025.2/Vivado/bin/vivado',
        VENTIUM_VIVADO_MEMORY_MAX=f'{ram_gib}G', VENTIUM_VIVADO_MEMORY_SWAP_MAX=f'{swap_gib}G',
        VENTIUM_VIVADO_TASK_PROFILE=task_profile,
        VENTIUM_VIVADO_LOCK_DIR=str(SCRATCH), VEN_FPGA_JOBS='1', VEN_FPGA_CORE_MHZ='40',
        VEN_FPGA_BUILD_PROFILE='balanced', VEN_FPGA_SKIP_PRESET='1',
        VEN_FPGA_SOURCE_ROOT=str(source/'ventium'), VEN_FPGA_FLOW_ROOT=str(source/'flow'),
        VEN_FPGA_TEMPLATE_ROOT=str(source/'template'), VEN_FPGA_DEFINE_FILE=str(source/'defines.txt'),
        VEN_FRESH_OUT=str(dest/'build'))
    launcher = REPO/'fpga/fresh_strategy.tcl'
    command = ['timeout', '--signal=TERM', '--kill-after=60s', f'{WHOLE_LIMIT}s',
        str(REPO/'fpga/run_vivado_exclusive.sh'), '-mode', 'batch', '-notrace',
        '-log', str(dest/'native.log'), '-journal', str(dest/'native.jou'),
        '-source', str(launcher), '-tclargs', args.strategy, str(source), str(dest/'build'), str(args.threads)]
    save(dest, 'started.json', dict(strategy=args.strategy, command=command, pins=pins,
        invocation=os.environ['INVOCATION_ID'], host=host(), disk_free=shutil.disk_usage(dest).free,
        env={k:v for k,v in env.items() if k.startswith(('VEN_', 'VENTIUM_')) or k == 'TMPDIR'},
        memory_profile=args.memory_profile, memory_max=ram_gib*GIB, swap_max=swap_gib*GIB,
        combined_limit=(ram_gib+swap_gib-1)*GIB, whole_limit_seconds=WHOLE_LIMIT,
        task_profile=task_profile, tasks_max=tasks_max, task_monitoring=True,
        implementation_limit_seconds=IMPL_LIMIT, prior_checkpoint_inputs=[],
        fresh_synthesis=True, tool_threads=args.threads, deployment=False, gameplay_ipc=None))
    interrupted = []
    signal.signal(signal.SIGTERM, lambda s,f: interrupted.append(s))
    signal.signal(signal.SIGINT, lambda s,f: interrupted.append(s))
    owner = reason = failure = None
    peak_ram = peak_swap = 0
    peak_tasks_sampled = task_limit_events = 0
    start = time.monotonic()
    with (dest/'guard.log').open('x') as log, (dest/'watch.jsonl').open('x') as watch:
        process = subprocess.Popen(command, cwd=dest, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                current = scope()
                if current['ActiveState'] == 'active':
                    group = Path('/sys/fs/cgroup'+current['ControlGroup'])
                    if not group.exists():
                        time.sleep(.1)
                        continue
                    if owner is None:
                        for pid in (group/'cgroup.procs').read_text().split():
                            try: cmd = Path('/proc', pid, 'cmdline').read_bytes()
                            except FileNotFoundError: continue
                            if str(dest/'native.log').encode() in cmd:
                                check_scope_limits(current, tasks_max, args.memory_profile)
                                owner = current
                                break
                    if owner:
                        assert current['InvocationID'] == owner['InvocationID']
                        limits = check_scope_limits(current, tasks_max, args.memory_profile)
                        pressure = task_pressure((group/'pids.current').read_text(),
                            (group/'pids.events').read_text(), tasks_max)
                        peak_tasks_sampled = max(peak_tasks_sampled, pressure['current'])
                        task_limit_events = max(task_limit_events, pressure['events']['max'])
                        ram = int((group/'memory.current').read_text())
                        swap = int((group/'memory.swap.current').read_text())
                        events = dict(r.split() for r in (group/'memory.events').read_text().splitlines())
                        peak_ram, peak_swap = max(peak_ram, ram), max(peak_swap, swap)
                        resources, free = host(), shutil.disk_usage(dest).free
                        reason = resource_stop(ram, swap, resources, free, events,
                            pressure['limit_hit'], ram_gib, swap_gib)
                        watch.write(json.dumps(dict(elapsed=time.monotonic()-start, memory=ram,
                            swap=swap, events=events, host=resources, disk_free=free, reason=reason,
                            limits=limits, tasks=pressure['current'], task_events=pressure['events']))+'\n')
                        watch.flush()
                if interrupted: reason = 'controller signal'
                if time.monotonic()-start > WHOLE_LIMIT: reason = 'whole-run deadline'
                stages = dest/'build/stages.tsv'
                if stages.exists() and stage_deadline(stages.read_text(), time.time()):
                    reason = 'implementation 3h50m deadline'
                if reason: break
                time.sleep(5)
        except BaseException as error:
            failure = repr(error)
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
    unchanged = all(sha(p) == h for p,h in pins.items())
    native_synth = measurements = None
    try:
        assert code == 0 and not reason and not failure and unchanged and owner
        assert 'FRESH-STRATEGY-COMPLETE '+args.strategy in (dest/'native.log').read_text()
        native_synth = validate_native_synth((dest/'build/rk_ao486_system/rk_ao486_system.runs/synth_1/rk_ao486_bd_wrapper.tcl').read_text(), args.strategy,
            (dest/'build/synth_1-properties.rpt').read_text(), args.threads)
        audit_impl((dest/'build/rk_ao486_system/rk_ao486_system.runs/impl_1/rk_ao486_bd_wrapper.tcl').read_text(),
            (dest/'build/impl_1-properties.rpt').read_text(), args.strategy, args.threads)
        measurements = validate_timing((dest/'build/timing.tsv').read_text())
        assert (dest/'build/fresh-routed.dcp').stat().st_size > 50_000_000
        assert (dest/'build/rk_ao486_system.bit.bin').stat().st_size > 10_000_000
    except Exception as error:
        failure = (failure+'; ' if failure else '')+'audit: '+repr(error)
    result = dict(completed=measurements is not None and not failure, native_exit=code,
        reason=reason, failure=failure, strategy=args.strategy, elapsed=time.monotonic()-start,
        inputs_unchanged=unchanged, owner=owner, peak_ram=peak_ram, peak_swap=peak_swap,
        memory_profile=args.memory_profile,
        task_profile=task_profile, tasks_max=tasks_max, peak_tasks_sampled=peak_tasks_sampled,
        task_limit_events=task_limit_events,
        native_synth=native_synth, measurements=measurements,
        products={p.name:sha(p) for p in (dest/'build').iterdir() if p.is_file()} if (dest/'build').exists() else {},
        # Coverage, pulse width, DRC/CDC/exceptions still require independent audit.
        timing_signoff=False, hardware_acceptance=False, gameplay_ipc=None)
    save(dest, 'closed.json', result)
    print(json.dumps(result, indent=2), flush=True)
    if not result['completed']: raise SystemExit(1)


if __name__ == '__main__': main()
