"""Full-cache A/B for explicit tag-way memories, preserving the prior fixture.

Run in ipc_parallel32 after the existing timing audit closes. This creates only
a private candidate, with actual CPU12 native observation and negative controls.
It does not launch full-core simulation, Vivado, routing or board programming.
"""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import time
import traceback

import prepare_way_banked_tags as recipe
from run_parallel_tag_cache import control_source, sha

REPO = Path(__file__).resolve().parents[2]
FIXTURE = '65c6bde806757d7537b94a953574c0a4fbb75cd1258b8c9e89a956132dd67068'
PRIOR = '3ffb3031b78800e507b71b6b2894dafc617ff963c7e666c2894bb40b41739516'


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def run_native(folder, group):
    model = (folder/'obj/test').resolve(strict=True)
    argv = [str(model), '+OBS='+str(folder/'cycles.txt')]
    observed, samples = None, []
    begin = time.monotonic()
    with (folder/'run.log').open('x') as log:
        child = subprocess.Popen(['taskset', '-c', '12', *argv], stdout=log,
            stderr=subprocess.STDOUT, start_new_session=True)
        proc = Path('/proc')/str(child.pid)
        try:
            while child.poll() is None:
                assert time.monotonic()-begin < 40, 'native wall limit'
                assert shutil.disk_usage(folder).free > 4*1024**3, 'disk reserve'
                if observed is None:
                    assert time.monotonic()-begin < 3, 'native admission timeout'
                    try:
                        sample = dict(pid=child.pid, exe=str((proc/'exe').resolve(strict=True)),
                            affinity=sorted(os.sched_getaffinity(child.pid)),
                            argv=(proc/'cmdline').read_bytes().rstrip(b'\0').decode().split('\0'),
                            cgroup=(proc/'cgroup').read_text())
                        if len(samples) < 256:
                            samples.append(sample)
                        if sample['exe']==str(model) and sample['affinity']==[12] and \
                                sample['argv']==argv and sample['cgroup']==group:
                            observed=sample
                    except (FileNotFoundError, ProcessLookupError):
                        pass
                time.sleep(.001 if observed is None else .01)
            code=child.wait(timeout=2)
            assert observed is not None, 'exited without positive native identity'
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=2)
            save(folder/'native.json', dict(argv=argv, observed=observed,
                startup_samples=samples, exit_code=child.returncode, reaped=not proc.exists(),
                seconds=time.monotonic()-begin))
    assert not proc.exists()
    return code


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', required=True, type=Path)
    args=ap.parse_args()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    data=scratch/'ventium-data-size.v2HaTO2X'
    root=args.out.resolve()
    assert __debug__ and root.is_relative_to(data) and root != data and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True)==scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free>5*1024**3
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE']=='ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT']=='ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN']=='/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'], check=True, pass_fds=(9,))
    assert subprocess.run(['pgrep','-x','vivado'], stdout=subprocess.DEVNULL).returncode==1
    clock=json.loads((data/'fp-compare-clock-r1/audit.json').read_text())
    assert clock['passed'] and clock['native_exit']==0 and not clock['routed']
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
        'MemoryMax=10G','MemorySwapMax=2G'], check=True)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    prior=data/'parallel-next-tag-cache-r1'
    assert sha(prior/'closed.json')==PRIOR and sha(prior/'tb_l1d_mem_chain.sv')==FIXTURE
    old=json.loads((prior/'closed.json').read_text())
    assert old['passed'] and old['pins_unchanged']
    pins=dict(old['pins'])
    pins.update(old['rows'][0]['artifacts'])
    assert all(sha(p)==h for p,h in pins.items())
    source=data/'fp-compare-core-r1/candidate/rtl/mem/ven_l1d.sv'
    original=source.read_text()
    changed=recipe.transform(original)
    assert original==(prior/'positive/ven_l1d.sv').read_text()
    root.mkdir()
    with (root/'control_l1d.sv').open('x') as f:
        f.write(control_source(original))
    with (root/'tb_l1d_mem_chain.sv').open('x') as f:
        f.write(recipe.miter_fixture((prior/'tb_l1d_mem_chain.sv').read_text()))
    for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),source,
              REPO/'verif/l1/run_parallel_tag_cache.py', REPO/'verif/l1/test_way_banked_tags.py',
              root/'control_l1d.sv',root/'tb_l1d_mem_chain.sv',prior/'closed.json',
              data/'fp-compare-clock-r1/audit.json'):
        pins[str(p)]=sha(p)
    save(root/'started.json',dict(pins=pins, invocation=os.environ['INVOCATION_ID'],
        controller_affinity=sorted(os.sched_getaffinity(0)), whole_core=False, gameplay_ipc=None))
    group=Path('/proc/self/cgroup').read_text()
    cg=Path('/sys/fs/cgroup')/group.split('::',1)[1].strip().lstrip('/')
    begin=time.monotonic()
    result=dict(passed=False,rows=[],error=None,whole_core=False,whole_cache=True,
        gameplay_ipc=None,timing_mhz=None,standard_suite=False,hardware_acceptance=False)
    try:
        variants=[('positive',changed),
            ('wrong-write-way',changed.replace('if (fway) dc_tag_way1[fset]',
                                               'if (!fway) dc_tag_way1[fset]')),
            ('wrong-snoop-way',changed.replace('dc_tag_way1[snp_set]', 'dc_tag_way0[snp_set]'))]
        for name,sv_text in variants:
            assert shutil.disk_usage(root).free > 5*1024**3
            folder=root/name
            folder.mkdir()
            sv=folder/'ven_l1d.sv'
            with sv.open('x') as f:
                f.write(sv_text)
            command=[s.replace(str(prior),str(root)).replace(str(root/'positive'),str(folder))
                     for s in old['rows'][0]['command']]
            assert command[command.index('-j')+1]=='32'
            assert sum(s.startswith('+define+') for s in command)==152
            assert '+define+VEN_L1D_TAG_LUTRAM' in command and '+define+VEN_PIPE_MEM_CHAIN' in command
            row=dict(name=name,command=command)
            result['rows'].append(row)
            with (folder/'build.log').open('x') as log:
                built=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,
                    env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=180)
            row['build_exit']=built.returncode
            assert built.returncode==0
            row['native_exit']=run_native(folder,group)
            log=(folder/'run.log').read_text()
            if name=='positive':
                assert row['native_exit']==0 and not re.search(r'%Error|%Fatal|FATAL|FAIL|MISMATCH|VACUOUS',log)
                for marker in ('L1D-MEM-CHAIN-OK accepted=150','WINDOW-WRITE-UPDATE-OK',
                    'STORE-WARM-OK','RESPONSE-PAYLOAD-OK','HIGH-WINDOW-PAYLOAD-OK',
                    'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4',
                    'PARALLEL-CACHE-MITER checks=747037 next=463',
                    'PARALLEL-NEXT-CACHE-COVERAGE hit=361977 owner=463 crossing=6984'):
                    assert marker in log,marker
                assert sha(folder/'cycles.txt')==sha(prior/'positive/cycles.txt')
            else:
                assert row['native_exit']!=0 and 'PARALLEL-CACHE-MISMATCH' in log
            row['artifacts']={str(p):sha(p) for p in (sv,folder/'obj/test',folder/'build.log',
                folder/'run.log',folder/'native.json',folder/'cycles.txt')}
            print(json.dumps({k:v for k,v in row.items() if k not in ('command','artifacts')}),flush=True)
        result['passed']=True
    except Exception:
        result['error']=traceback.format_exc()
    events=dict(line.split() for line in (cg/'memory.events').read_text().splitlines())
    result.update(seconds=time.monotonic()-begin,pins=pins,
        pins_unchanged=all(sha(p)==h for p,h in pins.items()),memory_events=events,
        memory_peak=int((cg/'memory.peak').read_text()),swap=int((cg/'memory.swap.current').read_text()))
    result['passed'] &= result['pins_unchanged'] and all(events[k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    save(root/'closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':
    raise SystemExit(main())
