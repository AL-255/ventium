"""Single guarded 40 MHz build; no retries, frequency variants or board writes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

from prepare_programmable_clock import DEST, REPO, sha

GIB = 1024**3
SCOPE = 'ventium-vivado.scope'


def host():
    return {r.split()[0].rstrip(':'):int(r.split()[1])*1024
            for r in Path('/proc/meminfo').read_text().splitlines()
            if r.startswith(('MemAvailable:', 'SwapFree:'))}


def scope():
    result = subprocess.check_output(['systemctl','--user','show',SCOPE,
        '-p','ActiveState','-p','InvocationID','-p','ControlGroup',
        '-p','MemoryMax','-p','MemorySwapMax','-p','TasksMax'], text=True, timeout=5)
    return dict(r.split('=',1) for r in result.splitlines() if '=' in r)


def save(name, data):
    with (DEST/name).open('x') as f:
        json.dump(data, f, indent=2)


def main():
    assert __debug__ and os.environ['TMPDIR'] == '/home/yukidama/external/tmp'
    assert os.environ['INVOCATION_ID'], 'run under a retained systemd user owner'
    assert DEST.stat().st_dev != REPO.stat().st_dev
    assert scope()['ActiveState'] in ('inactive','failed')
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    prepared = json.loads((DEST/'prepared.json').read_text())
    source = DEST/'source'
    pins = {str(source/n):h for n,h in prepared['source_pins'].items()}
    for p in (Path(__file__).resolve(), REPO/'fpga/launch_programmable_clock.tcl',
              REPO/'fpga/run_vivado_exclusive.sh', REPO/'tools/build_scope.sh', DEST/'prepared.json'):
        pins[str(p)] = sha(p)
    assert all(sha(Path(p)) == h for p,h in pins.items())
    assert host()['MemAvailable'] > 22*GIB and host()['SwapFree'] > 10*GIB
    assert shutil.disk_usage(DEST).free > 8*GIB
    (DEST/'once').mkdir()
    (DEST/'tool-tmp').mkdir()
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VENTIUM_','TB_','AXI_'))}
    env.update(TMPDIR=str(DEST/'tool-tmp'), VEN_FPGA_JOBS='1', VEN_FPGA_CORE_MHZ='40',
        VEN_FPGA_BUILD_PROFILE='logic_only', VEN_FPGA_SKIP_PRESET='1',
        VEN_FPGA_SOURCE_ROOT=str(source/'ventium'), VEN_FPGA_FLOW_ROOT=str(source/'flow'),
        VEN_FPGA_TEMPLATE_ROOT=str(source/'template'), VEN_FPGA_DEFINE_FILE=str(source/'defines.txt'),
        VENTIUM_VIVADO_MEMORY_MAX='20G', VENTIUM_VIVADO_MEMORY_SWAP_MAX='8G',
        VENTIUM_VIVADO_LOCK_DIR='/home/yukidama/external/tmp')
    launcher = REPO/'fpga/launch_programmable_clock.tcl'
    command = ['timeout','--signal=TERM','--kill-after=60s','6h',
        str(REPO/'fpga/run_vivado_exclusive.sh'),'-mode','batch',
        '-log',str(DEST/'native.log'),'-journal',str(DEST/'native.jou'),
        '-source',str(launcher),'-tclargs','all',str(DEST/'build')]
    save('started.json',dict(command=command, pins=pins, host=host(),
        disk_free=shutil.disk_usage(DEST).free, invocation=os.environ['INVOCATION_ID'],
        env={k:v for k,v in env.items() if k.startswith(('VEN_','VENTIUM_')) or k=='TMPDIR'},
        one_40mhz_image=True, standard_suite=False, gameplay_ipc=None))
    interrupted = []
    signal.signal(signal.SIGTERM, lambda s,f: interrupted.append(s))
    signal.signal(signal.SIGINT, lambda s,f: interrupted.append(s))
    owner = None
    reason = failure = None
    peak_ram = peak_swap = 0
    start = time.monotonic()
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
                        if any(str(launcher).encode() in Path('/proc',p,'cmdline').read_bytes()
                               for p in members if Path('/proc',p,'cmdline').exists()):
                            assert current['MemoryMax'] == str(20*GIB)
                            assert current['MemorySwapMax'] == str(8*GIB)
                            assert current['TasksMax'] == '48'
                            owner = current
                    if owner:
                        assert owner['InvocationID'] == current['InvocationID']
                        ram = int((group/'memory.current').read_text())
                        swap = int((group/'memory.swap.current').read_text())
                        events = dict(r.split() for r in (group/'memory.events').read_text().splitlines())
                        peak_ram, peak_swap = max(peak_ram,ram), max(peak_swap,swap)
                        resources, free = host(), shutil.disk_usage(DEST).free
                        if free < 4*GIB: reason = '4 GiB disk reserve'
                        elif min(resources.values()) < 2*GIB: reason = '2 GiB host RAM/swap reserve'
                        elif ram+swap > 27*GIB: reason = 'combined scope early stop'
                        elif int(events['oom']) or int(events['oom_kill']): reason = 'scope OOM'
                        elif interrupted: reason = 'controller signal'
                        watch.write(json.dumps(dict(elapsed=time.monotonic()-start, memory=ram,
                            swap=swap, events=events, host=resources, disk_free=free, reason=reason))+'\n')
                        watch.flush()
                if reason:
                    break
                time.sleep(5)
        except BaseException as exc:
            failure = repr(exc)
        finally:
            if process.poll() is None and (reason or failure):
                current = scope()
                if current['ActiveState'] == 'active':
                    assert owner and current['InvocationID'] == owner['InvocationID']
                    subprocess.run(['systemctl','--user','kill','--kill-whom=all','--signal=TERM',SCOPE],check=True)
                else:
                    process.terminate()
                try:
                    process.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    current = scope()
                    if current['ActiveState'] == 'active':
                        assert owner and current['InvocationID'] == owner['InvocationID']
                        subprocess.run(['systemctl','--user','kill','--kill-whom=all','--signal=KILL',SCOPE],check=True)
                    process.kill()
            code = process.wait(timeout=60)
    unchanged = all(sha(Path(p)) == h for p,h in pins.items())
    products = {str(p.relative_to(DEST)):sha(p) for p in (DEST/'build').glob('*.bit*')}
    native_complete = 'PROGRAMMABLE-CLOCK-BUILD-COMPLETE' in (DEST/'native.log').read_text(errors='replace')
    passed = code==0 and not reason and not failure and unchanged and native_complete and len(products)==2
    save('closed.json',dict(passed=passed, native_exit=code, reason=reason, failure=failure,
        owner=owner, elapsed=time.monotonic()-start, inputs_unchanged=unchanged,
        peak_ram=peak_ram, peak_swap=peak_swap, products=products,
        standard_suite=False, gameplay_ipc=None, hardware_acceptance=False))
    print(json.dumps(dict(passed=passed, native_exit=code, reason=reason, failure=failure)),flush=True)
    if not passed:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
