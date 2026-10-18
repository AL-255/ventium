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
from audit_fresh_strategy import audit_synth

ANCESTOR = SCRATCH/'ventium-fprem-sequence.iSZ9BAj4/programmable-clock-r3'
PREPARED_SHA = '5308f8044f35b387e833e1b62a52ec7605bb3a5e157096d9327b638d4b659a54'
REPAIRED = SCRATCH/'ventium-fprem-sequence.iSZ9BAj4/programmable-clock-power-repair-r5/source'
CLOCK_HASHES = {
    'ven_pll_ctrl.sv': '02f1cd73c2d8a13181dc605a89850e0513c84a9fb2c510784ab5b56e830a1237',
    'ven_programmable_clock.v': 'cea6e80e4ca1240bfb2b1d3920c869458e21e30f19aa96fe77743be86109d2e9',
}
STRATEGIES = ('performance-netdelay', 'routability-spread')
RAM_GIB, SWAP_GIB = 16, 6
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
                 'fresh_route_pre.tcl', 'fresh_reports.tcl', 'run_apr_trial.py',
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


def validate_native_synth(text, strategy, properties):
    # Vivado omits default-valued arguments from its generated command. The
    # actual property report, not the spelling of a default, is the authority.
    return audit_synth(text, properties, strategy)['command']


def stage_deadline(text, now):
    rows = [r.split('\t') for r in text.splitlines()]
    starts = [int(t) for name, t in rows if name == 'impl_1']
    if len(starts) > 1:
        raise ValueError('duplicate implementation launch')
    return bool(starts and now-starts[0] >= IMPL_LIMIT)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--strategy', choices=STRATEGIES, required=True)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    assert __debug__ and os.environ['TMPDIR'] == str(SCRATCH)
    assert os.environ.get('INVOCATION_ID'), 'use a retained systemd owner'
    dest = args.output.resolve()
    assert dest.is_relative_to(SCRATCH.resolve()) and dest != SCRATCH.resolve() and not dest.exists()
    assert dest.parent.is_dir() and dest.parent.stat().st_dev == SCRATCH.stat().st_dev != REPO.stat().st_dev
    assert os.access(SCRATCH, os.W_OK)
    assert scope()['ActiveState'] in ('inactive', 'failed')
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    assert host()['MemAvailable'] > (RAM_GIB+2)*GIB and host()['SwapFree'] > (SWAP_GIB+4)*GIB
    assert shutil.disk_usage(SCRATCH).free > 7*GIB
    pins = prepare(dest)
    (dest/'tool-tmp').mkdir()
    source = dest/'source'
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'VENTIUM_', 'TB_', 'AXI_'))}
    env.update(TMPDIR=str(dest/'tool-tmp'), VIVADO_BIN='/tools/Xilinx/2025.2/Vivado/bin/vivado',
        VENTIUM_VIVADO_MEMORY_MAX=f'{RAM_GIB}G', VENTIUM_VIVADO_MEMORY_SWAP_MAX=f'{SWAP_GIB}G',
        VENTIUM_VIVADO_LOCK_DIR=str(SCRATCH), VEN_FPGA_JOBS='1', VEN_FPGA_CORE_MHZ='40',
        VEN_FPGA_BUILD_PROFILE='balanced', VEN_FPGA_SKIP_PRESET='1',
        VEN_FPGA_SOURCE_ROOT=str(source/'ventium'), VEN_FPGA_FLOW_ROOT=str(source/'flow'),
        VEN_FPGA_TEMPLATE_ROOT=str(source/'template'), VEN_FPGA_DEFINE_FILE=str(source/'defines.txt'),
        VEN_FRESH_OUT=str(dest/'build'))
    launcher = REPO/'fpga/fresh_strategy.tcl'
    command = ['timeout', '--signal=TERM', '--kill-after=60s', f'{WHOLE_LIMIT}s',
        str(REPO/'fpga/run_vivado_exclusive.sh'), '-mode', 'batch', '-notrace',
        '-log', str(dest/'native.log'), '-journal', str(dest/'native.jou'),
        '-source', str(launcher), '-tclargs', args.strategy, str(source), str(dest/'build')]
    save(dest, 'started.json', dict(strategy=args.strategy, command=command, pins=pins,
        invocation=os.environ['INVOCATION_ID'], host=host(), disk_free=shutil.disk_usage(dest).free,
        env={k:v for k,v in env.items() if k.startswith(('VEN_', 'VENTIUM_')) or k == 'TMPDIR'},
        memory_max=RAM_GIB*GIB, swap_max=SWAP_GIB*GIB, whole_limit_seconds=WHOLE_LIMIT,
        implementation_limit_seconds=IMPL_LIMIT, prior_checkpoint_inputs=[],
        fresh_synthesis=True, deployment=False, gameplay_ipc=None))
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
                    if not group.exists():
                        time.sleep(.1)
                        continue
                    if owner is None:
                        for pid in (group/'cgroup.procs').read_text().split():
                            try: cmd = Path('/proc', pid, 'cmdline').read_bytes()
                            except FileNotFoundError: continue
                            if str(dest/'native.log').encode() in cmd:
                                assert current['MemoryMax'] == str(RAM_GIB*GIB)
                                assert current['MemorySwapMax'] == str(SWAP_GIB*GIB) and current['TasksMax'] == '48'
                                owner = current
                                break
                    if owner:
                        assert current['InvocationID'] == owner['InvocationID']
                        ram = int((group/'memory.current').read_text())
                        swap = int((group/'memory.swap.current').read_text())
                        events = dict(r.split() for r in (group/'memory.events').read_text().splitlines())
                        peak_ram, peak_swap = max(peak_ram, ram), max(peak_swap, swap)
                        resources, free = host(), shutil.disk_usage(dest).free
                        if free < 4*GIB: reason = '4 GiB disk reserve'
                        elif min(resources.values()) < 2*GIB: reason = '2 GiB host RAM/swap reserve'
                        elif ram+swap > (RAM_GIB+SWAP_GIB-1)*GIB: reason = 'combined memory early stop'
                        elif int(events['oom']) or int(events['oom_kill']): reason = 'scope OOM'
                        watch.write(json.dumps(dict(elapsed=time.monotonic()-start, memory=ram,
                            swap=swap, events=events, host=resources, disk_free=free, reason=reason))+'\n')
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
            (dest/'build/synth_1-properties.rpt').read_text())
        measurements = validate_timing((dest/'build/timing.tsv').read_text())
        assert (dest/'build/fresh-routed.dcp').stat().st_size > 50_000_000
        assert (dest/'build/rk_ao486_system.bit.bin').stat().st_size > 10_000_000
    except Exception as error:
        failure = (failure+'; ' if failure else '')+'audit: '+repr(error)
    result = dict(completed=measurements is not None and not failure, native_exit=code,
        reason=reason, failure=failure, strategy=args.strategy, elapsed=time.monotonic()-start,
        inputs_unchanged=unchanged, owner=owner, peak_ram=peak_ram, peak_swap=peak_swap,
        native_synth=native_synth, measurements=measurements,
        products={p.name:sha(p) for p in (dest/'build').iterdir() if p.is_file()} if (dest/'build').exists() else {},
        # Coverage, pulse width, DRC/CDC/exceptions still require independent audit.
        timing_signoff=False, hardware_acceptance=False, gameplay_ipc=None)
    save(dest, 'closed.json', result)
    print(json.dumps(result, indent=2), flush=True)
    if not result['completed']: raise SystemExit(1)


if __name__ == '__main__': main()
