"""Bounded, read-only checkpoint inspection before the next 40 MHz route."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

from prepare_programmable_clock import REPO, sha
from run_programmable_clock_build import host, scope, GIB, SCOPE

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4')
DEST = ROOT/'programmable-clock-congestion-r1'
R3 = ROOT/'programmable-clock-r3'
PARENT = ROOT/'parallel-write-implementation-r1/project/rk_ao486_system.runs/impl_1/rk_ao486_bd_wrapper_routed.dcp'
CANDIDATE = R3/'build/rk_ao486_system/rk_ao486_system.runs/impl_1/rk_ao486_bd_wrapper_physopt.dcp'


def main():
    assert __debug__ and os.environ['TMPDIR'] == '/home/yukidama/external/tmp'
    assert os.environ['INVOCATION_ID'] and not DEST.exists()
    assert ROOT.stat().st_dev != REPO.stat().st_dev
    assert scope()['ActiveState'] in ('inactive', 'failed')
    assert subprocess.run(['pgrep', '-x', 'vivado'], stdout=subprocess.DEVNULL).returncode == 1
    prior = json.loads((R3/'closed.json').read_text())
    assert prior['native_exit'] == 143 and prior['reason'] == 'controller signal'
    assert prior['inputs_unchanged'] and prior['products'] == {}
    assert sha(PARENT) == 'c932cefb2909e0934c83d105fc8aaebc3e51beb0c2b899b43738462eb54d76a5'
    pins = json.loads((R3/'started.json').read_text())['pins']
    script = REPO/'fpga/audit_programmable_congestion.tcl'
    for path in (PARENT, CANDIDATE, script, Path(__file__).resolve(), R3/'closed.json'):
        pins[str(path)] = sha(path)
    assert all(sha(Path(path)) == digest for path, digest in pins.items())
    assert host()['MemAvailable'] > 10*GIB and host()['SwapFree'] > 8*GIB
    assert shutil.disk_usage(ROOT).free > 6*GIB
    DEST.mkdir()
    (DEST/'tool-tmp').mkdir()
    (DEST/'reports').mkdir()
    def save(name, data):
        with (DEST/name).open('x') as stream:
            json.dump(data, stream, indent=2)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_', 'VENTIUM_', 'TB_', 'AXI_'))}
    env.update(TMPDIR=str(DEST/'tool-tmp'), VENTIUM_VIVADO_MEMORY_MAX='8G',
               VENTIUM_VIVADO_MEMORY_SWAP_MAX='4G', VENTIUM_VIVADO_LOCK_DIR='/home/yukidama/external/tmp')
    command = ['timeout', '--signal=TERM', '--kill-after=60s', '20m',
               str(REPO/'fpga/run_vivado_exclusive.sh'), '-mode', 'batch',
               '-log', str(DEST/'native.log'), '-journal', str(DEST/'native.jou'),
               '-source', str(script), '-tclargs', str(PARENT), str(CANDIDATE), str(DEST/'reports')]
    save('started.json', dict(command=command, pins=pins, host=host(),
         invocation=os.environ['INVOCATION_ID'], read_only_checkpoints=True,
         memory_max=8*GIB, swap_max=4*GIB, synthesis=False, implementation=False))
    interrupted = []
    signal.signal(signal.SIGTERM, lambda s,f: interrupted.append(s))
    signal.signal(signal.SIGINT, lambda s,f: interrupted.append(s))
    start = time.monotonic()
    owner = reason = failure = None
    peak_ram = peak_swap = 0
    with (DEST/'guard.log').open('x') as log, (DEST/'watch.jsonl').open('x') as watch:
        process = subprocess.Popen(command, cwd=DEST, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                current = scope()
                if current['ActiveState'] == 'active':
                    group = Path('/sys/fs/cgroup'+current['ControlGroup'])
                    if not group.exists():
                        time.sleep(.1)
                        continue
                    if owner is None:
                        members = (group/'cgroup.procs').read_text().split()
                        if any(str(script).encode() in Path('/proc',pid,'cmdline').read_bytes()
                               for pid in members if Path('/proc',pid,'cmdline').exists()):
                            assert current['MemoryMax'] == str(8*GIB)
                            assert current['MemorySwapMax'] == str(4*GIB)
                            assert current['TasksMax'] == '48'
                            owner = current
                    if owner:
                        assert current['InvocationID'] == owner['InvocationID']
                        ram = int((group/'memory.current').read_text())
                        swap = int((group/'memory.swap.current').read_text())
                        events = dict(line.split() for line in (group/'memory.events').read_text().splitlines())
                        peak_ram, peak_swap = max(peak_ram, ram), max(peak_swap, swap)
                        resources, free = host(), shutil.disk_usage(DEST).free
                        if free < 4*GIB: reason = '4 GiB disk reserve'
                        elif min(resources.values()) < 2*GIB: reason = '2 GiB host RAM/swap reserve'
                        elif int(events['oom']) or int(events['oom_kill']): reason = 'scope OOM'
                        elif interrupted: reason = 'controller signal'
                        watch.write(json.dumps(dict(elapsed=time.monotonic()-start, memory=ram,
                            swap=swap, events=events, host=resources, disk_free=free, reason=reason))+'\n')
                        watch.flush()
                if reason: break
                time.sleep(5)
        except BaseException as error:
            failure = repr(error)
        finally:
            if process.poll() is None and (reason or failure):
                current = scope()
                if current['ActiveState'] == 'active':
                    assert owner and current['InvocationID'] == owner['InvocationID']
                    subprocess.run(['systemctl','--user','kill','--kill-whom=all','--signal=TERM',SCOPE], check=True)
                else: process.terminate()
                try: process.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    current = scope()
                    if current['ActiveState'] == 'active':
                        assert owner and current['InvocationID'] == owner['InvocationID']
                        subprocess.run(['systemctl','--user','kill','--kill-whom=all','--signal=KILL',SCOPE], check=True)
                    process.kill()
            code = process.wait(timeout=60)
    unchanged = all(sha(Path(path)) == digest for path, digest in pins.items())
    complete = 'PROGRAMMABLE-CONGESTION-AUDIT-COMPLETE' in (DEST/'native.log').read_text(errors='replace')
    products = {p.name:sha(p) for p in (DEST/'reports').iterdir() if p.is_file()}
    passed = code == 0 and not reason and not failure and unchanged and complete
    save('closed.json', dict(passed=passed, native_exit=code, reason=reason, failure=failure,
         elapsed=time.monotonic()-start, inputs_unchanged=unchanged, products=products,
         owner=owner, peak_ram=peak_ram, peak_swap=peak_swap, hardware_acceptance=False))
    print(json.dumps(dict(passed=passed, native_exit=code, reason=reason, failure=failure)), flush=True)
    if not passed: raise SystemExit(1)


if __name__ == '__main__': main()
