"""One bounded physical-layout retry; unchanged 40 MHz netlist, no synthesis."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

from prepare_programmable_clock import REPO, sha
from run_programmable_clock_build import host, scope, GIB, SCOPE

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4')
DEST = ROOT/'programmable-clock-reuse-r2'
PRIOR = ROOT/'programmable-clock-reuse-r1'
R3 = ROOT/'programmable-clock-r3'
AUDIT = ROOT/'programmable-clock-congestion-r1'
PARENT = ROOT/'parallel-write-implementation-r1/project/rk_ao486_system.runs/impl_1/rk_ao486_bd_wrapper_routed.dcp'
CURRENT = R3/'build/rk_ao486_system/rk_ao486_system.runs/impl_1/rk_ao486_bd_wrapper_opt.dcp'
WHOLE_RUN_LIMIT_SECONDS = 13800


def validate_reports(route, drc, clocks, route_time, initial, placed):
    counts = {}
    for name in ('routable nets', 'fully routed nets', 'nets with routing errors'):
        matches = re.findall(r'# of '+re.escape(name)+r'\.+\s*:\s*(\d+)\s*:', route)
        if len(matches) != 1: raise ValueError('missing/ambiguous route count: '+name)
        counts[name] = int(matches[0])
    if not counts['routable nets'] == counts['fully routed nets'] > 200000:
        raise ValueError('incomplete routing or missing processor')
    if counts['nets with routing errors']:
        raise ValueError('routing errors')
    if not re.search(r'Design State\s*:\s*Fully Routed', drc):
        raise ValueError('DRC not fully routed')
    if re.search(r'\|\s*(?:Error|Critical Warning)\s*\|', drc):
        raise ValueError('DRC error/critical warning')
    for name, period in (('mmcm_clk','25.000'), ('clk_pl_0','10.000')):
        if len(re.findall(r'^'+name+r'\s+'+re.escape(period)+r'\s', clocks, re.M)) != 1:
            raise ValueError('incorrect clock: '+name)
    if route_time['limit_ms'] != 14400000 or not 0 <= route_time['route_elapsed_ms'] < 14400000:
        raise ValueError('route did not meet strict four-hour bound')
    for expected, row in (('initial', initial), ('placed', placed)):
        if row['stage'] != expected or row['primitive_cells'] < 200000:
            raise ValueError('bad reuse witness')
        if not 95 <= row['matched_pct'] <= 100 or not 90 <= row['reused_pct'] <= 100:
            raise ValueError('insufficient reuse')
    return counts


def main():
    assert __debug__ and os.environ['TMPDIR'] == '/home/yukidama/external/tmp'
    assert os.environ['INVOCATION_ID'] and not DEST.exists()
    assert ROOT.stat().st_dev != REPO.stat().st_dev
    assert scope()['ActiveState'] in ('inactive','failed')
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode == 1
    prior = json.loads((PRIOR/'closed.json').read_text())
    assert not prior['passed'] and prior['native_exit'] == 1 and prior['inputs_unchanged']
    reuse = json.loads((PRIOR/'build/initial-reuse.json').read_text())
    assert reuse['matched_pct'] >= 95 and reuse['reused_pct'] == 0
    assert 'Flow is switching to default flow due to incremental criteria not met.' in (PRIOR/'native.log').read_text()
    audit = json.loads((AUDIT/'closed.json').read_text())
    assert audit['passed'] and audit['native_exit'] == 0 and audit['inputs_unchanged']
    assert sha(PARENT) == 'c932cefb2909e0934c83d105fc8aaebc3e51beb0c2b899b43738462eb54d76a5'
    pins = json.loads((AUDIT/'started.json').read_text())['pins']
    script = REPO/'fpga/launch_programmable_incremental.tcl'
    for path in (CURRENT, script, Path(__file__).resolve(), AUDIT/'closed.json',
                 PRIOR/'closed.json', PRIOR/'native.log', PRIOR/'build/initial-reuse.json',
                 REPO/'fpga/prepare_programmable_clock.py', REPO/'fpga/test_programmable_incremental.py'):
        pins[str(path)] = sha(path)
    for name, digest in audit['products'].items():
        pins[str(AUDIT/'reports'/name)] = digest
    assert all(sha(Path(path)) == digest for path,digest in pins.items())
    assert host()['MemAvailable'] > 14*GIB and host()['SwapFree'] > 8*GIB
    assert shutil.disk_usage(ROOT).free > 6*GIB
    DEST.mkdir()
    for name in ('tool-tmp','build'): (DEST/name).mkdir()
    def save(name, data):
        with (DEST/name).open('x') as stream: json.dump(data, stream, indent=2)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VENTIUM_','TB_','AXI_'))}
    env.update(TMPDIR=str(DEST/'tool-tmp'), VIVADO_BIN='/tools/Xilinx/2025.2/Vivado/bin/vivado',
               VENTIUM_VIVADO_MEMORY_MAX='12G', VENTIUM_VIVADO_MEMORY_SWAP_MAX='4G',
               VENTIUM_VIVADO_LOCK_DIR='/home/yukidama/external/tmp')
    command = ['timeout','--signal=TERM','--kill-after=60s',f'{WHOLE_RUN_LIMIT_SECONDS}s',
               str(REPO/'fpga/run_vivado_exclusive.sh'),'-mode','batch',
               '-log',str(DEST/'native.log'),'-journal',str(DEST/'native.jou'),
               '-source',str(script),'-tclargs',str(CURRENT),str(PARENT),str(DEST/'build')]
    save('started.json',dict(command=command,pins=pins,host=host(),
         invocation=os.environ['INVOCATION_ID'],synthesis=False,rtl_changed=False,
         constraint_core_mhz=40,constraint_axi_mhz=100,memory_max=12*GIB,swap_max=4*GIB,
         whole_run_limit_seconds=WHOLE_RUN_LIMIT_SECONDS,required_route_seconds_less_than=14400))
    interrupted = []
    signal.signal(signal.SIGTERM,lambda s,f:interrupted.append(s))
    signal.signal(signal.SIGINT,lambda s,f:interrupted.append(s))
    start = time.monotonic()
    owner = reason = failure = None
    peak_ram = peak_swap = 0
    with (DEST/'guard.log').open('x') as log, (DEST/'watch.jsonl').open('x') as watch:
        process = subprocess.Popen(command,cwd=DEST,env=env,stdout=log,stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                current = scope()
                if current['ActiveState'] == 'active':
                    group = Path('/sys/fs/cgroup'+current['ControlGroup'])
                    if not group.exists():
                        time.sleep(.1); continue
                    if owner is None:
                        members = (group/'cgroup.procs').read_text().split()
                        if any(str(script).encode() in Path('/proc',pid,'cmdline').read_bytes()
                               for pid in members if Path('/proc',pid,'cmdline').exists()):
                            assert current['MemoryMax'] == str(12*GIB)
                            assert current['MemorySwapMax'] == str(4*GIB)
                            assert current['TasksMax'] == '48'
                            owner = current
                    if owner:
                        assert current['InvocationID'] == owner['InvocationID']
                        ram = int((group/'memory.current').read_text())
                        swap = int((group/'memory.swap.current').read_text())
                        events = dict(line.split() for line in (group/'memory.events').read_text().splitlines())
                        peak_ram,peak_swap = max(peak_ram,ram),max(peak_swap,swap)
                        resources,free = host(),shutil.disk_usage(DEST).free
                        if free < 4*GIB: reason = '4 GiB disk reserve'
                        elif min(resources.values()) < 2*GIB: reason = '2 GiB host RAM/swap reserve'
                        elif int(events['oom']) or int(events['oom_kill']): reason = 'scope OOM'
                        elif interrupted: reason = 'controller signal'
                        watch.write(json.dumps(dict(elapsed=time.monotonic()-start,memory=ram,
                            swap=swap,events=events,host=resources,disk_free=free,reason=reason))+'\n')
                        watch.flush()
                if reason: break
                time.sleep(5)
        except BaseException as error: failure = repr(error)
        finally:
            if process.poll() is None and (reason or failure):
                current = scope()
                if current['ActiveState'] == 'active':
                    assert owner and current['InvocationID'] == owner['InvocationID']
                    subprocess.run(['systemctl','--user','kill','--kill-whom=all','--signal=TERM',SCOPE],check=True)
                else: process.terminate()
                try: process.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    current = scope()
                    if current['ActiveState'] == 'active':
                        assert owner and current['InvocationID'] == owner['InvocationID']
                        subprocess.run(['systemctl','--user','kill','--kill-whom=all','--signal=KILL',SCOPE],check=True)
                    process.kill()
            code = process.wait(timeout=60)
    elapsed = time.monotonic()-start
    unchanged = all(sha(Path(path)) == digest for path,digest in pins.items())
    build = DEST/'build'
    products = {p.name:sha(p) for p in build.iterdir() if p.is_file()}
    checked = None
    try:
        assert code == 0 and not reason and not failure and unchanged and elapsed < 14400
        assert re.search(r'^PROGRAMMABLE-INCREMENTAL-COMPLETE ',(DEST/'native.log').read_text(),re.M)
        checked = validate_reports((build/'route-status.rpt').read_text(),(build/'drc.rpt').read_text(),
            (build/'clocks.rpt').read_text(),json.loads((build/'route-time.json').read_text()),
            json.loads((build/'initial-reuse.json').read_text()),json.loads((build/'placed-reuse.json').read_text()))
        assert (build/'ventium_programmable_clock_40.bit').stat().st_size > 1_000_000
        with (build/'ventium_programmable_clock_40.bin').open('rb') as stream:
            assert stream.read(84)[0x50:0x54] == bytes.fromhex('aa995566')
    except Exception as error:
        failure = (failure+'; ' if failure else '')+'product audit: '+repr(error)
    passed = checked is not None and not failure
    save('closed.json',dict(passed=passed,native_exit=code,reason=reason,failure=failure,
        elapsed=elapsed,inputs_unchanged=unchanged,products=products,route_counts=checked,
        owner=owner,peak_ram=peak_ram,peak_swap=peak_swap,standard_suite=False,
        timing_signoff=False,hardware_acceptance=False,gameplay_ipc=None))
    print(json.dumps(dict(passed=passed,native_exit=code,reason=reason,failure=failure)),flush=True)
    if not passed: raise SystemExit(1)


if __name__ == '__main__': main()
