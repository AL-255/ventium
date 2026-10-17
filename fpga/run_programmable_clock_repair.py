"""One bounded clock-leaf repair, with preserved CPU netlist and physical reuse."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

from prepare_programmable_clock import REPO, sha
from prepare_programmable_clock_repair import DEST
from run_programmable_clock_build import host, scope, GIB, SCOPE
from run_programmable_incremental import validate_reports
from audit_clock_reuse import validate as validate_canonical


def main():
    assert __debug__ and os.environ['TMPDIR'] == '/home/yukidama/external/tmp'
    assert os.environ['INVOCATION_ID'] and not (DEST/'started.json').exists()
    assert DEST.stat().st_dev != REPO.stat().st_dev
    assert scope()['ActiveState'] in ('inactive','failed')
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode == 1
    prepared = json.loads((DEST/'prepared.json').read_text())
    pins = prepared['pins'] | prepared['source_pins']
    script = REPO/'fpga/launch_programmable_clock_repair.tcl'
    for p in (script, Path(__file__).resolve(), DEST/'prepared.json',
              REPO/'fpga/run_vivado_exclusive.sh', REPO/'tools/build_scope.sh',
              REPO/'fpga/audit_clock_eco_netlists.py', REPO/'fpga/test_programmable_clock_netlist.sh',
              REPO/'fpga/tb_programmable_clock_netlist.sv', REPO/'fpga/run_programmable_incremental.py',
              REPO/'fpga/run_programmable_clock_build.py', REPO/'fpga/prepare_programmable_clock.py',
              REPO/'fpga/prepare_programmable_clock_repair.py', REPO/'fpga/audit_clock_reuse.py'):
        pins[str(p)] = sha(p)
    assert all(sha(Path(p)) == h for p,h in pins.items())
    assert host()['MemAvailable'] > 10*GIB and host()['SwapFree'] > 8*GIB
    assert shutil.disk_usage(DEST).free > 6*GIB
    build = DEST/'build'
    build.mkdir()
    if prepared.get('resume_checkpoint'):
        shutil.copy2(prepared['resume_soc_before'],build/'soc-before.v')
    (DEST/'tool-tmp').mkdir()
    def save(name, data):
        with (DEST/name).open('x') as stream: json.dump(data, stream, indent=2)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VENTIUM_','TB_','AXI_'))}
    env.update(TMPDIR=str(DEST/'tool-tmp'), VIVADO_BIN='/tools/Xilinx/2025.2/Vivado/bin/vivado',
        VENTIUM_VIVADO_MEMORY_MAX='8G', VENTIUM_VIVADO_MEMORY_SWAP_MAX='4G',
        VENTIUM_VIVADO_LOCK_DIR='/home/yukidama/external/tmp')
    command = ['timeout','--signal=TERM','--kill-after=60s','13800s',
        str(REPO/'fpga/run_vivado_exclusive.sh'),'-mode','batch',
        '-log',str(DEST/'native.log'),'-journal',str(DEST/'native.jou'),
        '-source',str(script),'-tclargs',prepared['parent_checkpoint'],
        str(DEST/'source'),str(build),str(REPO)]
    if prepared.get('resume_checkpoint'): command.append(prepared['resume_checkpoint'])
    save('started.json',dict(command=command,pins=pins,host=host(),
        invocation=os.environ['INVOCATION_ID'],synthesis_scope=prepared['synthesis_scope'],
        processor_rtl_changed=False,constraint_core_mhz=40,constraint_axi_mhz=100,
        memory_max=8*GIB,swap_max=4*GIB,whole_run_limit_seconds=13800))
    interrupted=[]
    signal.signal(signal.SIGTERM,lambda s,f:interrupted.append(s))
    signal.signal(signal.SIGINT,lambda s,f:interrupted.append(s))
    start=time.monotonic()
    owner=reason=failure=None
    peak_ram=peak_swap=0
    with (DEST/'guard.log').open('x') as log, (DEST/'watch.jsonl').open('x') as watch:
        process=subprocess.Popen(command,cwd=DEST,env=env,stdout=log,stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                current=scope()
                if current['ActiveState']=='active':
                    group=Path('/sys/fs/cgroup'+current['ControlGroup'])
                    if not group.exists():
                        time.sleep(.1); continue
                    if owner is None:
                        members=(group/'cgroup.procs').read_text().split()
                        if any(str(script).encode() in Path('/proc',pid,'cmdline').read_bytes()
                               for pid in members if Path('/proc',pid,'cmdline').exists()):
                            assert current['MemoryMax']==str(8*GIB)
                            assert current['MemorySwapMax']==str(4*GIB)
                            assert current['TasksMax']=='48'
                            owner=current
                    if owner:
                        assert current['InvocationID']==owner['InvocationID']
                        ram=int((group/'memory.current').read_text())
                        swap=int((group/'memory.swap.current').read_text())
                        events=dict(line.split() for line in (group/'memory.events').read_text().splitlines())
                        peak_ram,peak_swap=max(peak_ram,ram),max(peak_swap,swap)
                        resources,free=host(),shutil.disk_usage(DEST).free
                        if free < 4*GIB: reason='4 GiB disk reserve'
                        elif min(resources.values()) < 2*GIB: reason='2 GiB host RAM/swap reserve'
                        elif int(events['oom']) or int(events['oom_kill']): reason='scope OOM'
                        watch.write(json.dumps(dict(elapsed=time.monotonic()-start,memory=ram,
                            swap=swap,events=events,host=resources,disk_free=free,reason=reason))+'\n')
                        watch.flush()
                if interrupted: reason='controller signal'
                if reason: break
                time.sleep(5)
        except BaseException as error: failure=repr(error)
        finally:
            if process.poll() is None and (reason or failure):
                current=scope()
                if current['ActiveState']=='active':
                    assert owner and current['InvocationID']==owner['InvocationID']
                    subprocess.run(['systemctl','--user','kill','--kill-whom=all','--signal=TERM',SCOPE],check=True)
                else: process.terminate()
                try: process.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    current=scope()
                    if current['ActiveState']=='active':
                        assert owner and current['InvocationID']==owner['InvocationID']
                        subprocess.run(['systemctl','--user','kill','--kill-whom=all','--signal=KILL',SCOPE],check=True)
                    process.kill()
            code=process.wait(timeout=60)
    elapsed=time.monotonic()-start
    unchanged=all(sha(Path(p))==h for p,h in pins.items())
    checked=None
    try:
        assert code==0 and not reason and not failure and unchanged and owner and elapsed<14400
        assert re.search(r'^PROGRAMMABLE-CLOCK-REPAIR-COMPLETE ',(DEST/'native.log').read_text(),re.M)
        initial=json.loads((build/'initial-reuse.json').read_text())
        placed=json.loads((build/'placed-reuse.json').read_text())
        assert min(initial['matched_pct'],placed['matched_pct'])>=95
        assert min(initial['reused_pct'],placed['reused_pct'])>=99
        for stage in ('initial','placed'):
            canonical=validate_canonical((build/(stage+'-reuse.rpt')).read_text())
            assert canonical==json.loads((build/(stage+'-canonical-reuse.json')).read_text())
        checked=validate_reports((build/'route-status.rpt').read_text(),(build/'drc.rpt').read_text(),
            (build/'clocks.rpt').read_text(),json.loads((build/'route-time.json').read_text()),initial,placed)
        assert json.loads((build/'soc-unchanged.json').read_text())['identical'] is True
        for stage in ('netlist-preplace','netlist-postroute'):
            assert 'PROGRAMMABLE-CLOCK-NETLIST-OK' in (build/(stage+'.log')).read_text()
        assert (build/'ventium_programmable_clock_40.bit').stat().st_size>1_000_000
        with (build/'ventium_programmable_clock_40.bin').open('rb') as stream:
            assert stream.read(84)[0x50:0x54]==bytes.fromhex('aa995566')
    except Exception as error:
        failure=(failure+'; ' if failure else '')+'product audit: '+repr(error)
    products={p.name:sha(p) for p in build.iterdir() if p.is_file()}
    passed=checked is not None and not failure
    save('closed.json',dict(passed=passed,native_exit=code,reason=reason,failure=failure,
        elapsed=elapsed,inputs_unchanged=unchanged,products=products,route_counts=checked,
        owner=owner,peak_ram=peak_ram,peak_swap=peak_swap,standard_suite=False,
        timing_signoff=False,hardware_acceptance=False,gameplay_ipc=None))
    print(json.dumps(dict(passed=passed,native_exit=code,reason=reason,failure=failure)),flush=True)
    if not passed: raise SystemExit(1)


if __name__ == '__main__': main()
