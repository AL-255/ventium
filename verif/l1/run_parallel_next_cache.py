"""Reuse the closed full-P5 public-traffic fixture for next-line tag A/B.

No root RTL edits, new feature switches, private state injection or Vivado run.
The immutable earlier fixture and all its bank/tag/owner comparisons remain;
add direct next-line hit checks and coverage, not replacement stimuli.
"""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import shutil
import subprocess
import time

import prepare_parallel_next_tag as recipe
from run_parallel_tag_cache import control_source, sha

REPO = Path(__file__).resolve().parents[2]
FIXTURE = '79d2b376c09286b517b245ab34ccba46a141ba9aedf16d08ae90c2cf68752773'
LEAF = '4b8146a8fb914de0d5fc3314d28e5c613a31907b00010d2cfe534f18df5e95b8'
PARENT = 'fb1f0bba0ca3eb0ab4e9d336f98985c85af2eea72a680b611862e3c055f4cfcb'


def bench(text):
    anchor = '    parallel_cache_checks++;'
    assert text.count(anchor) == 1 and text.count('  integer parallel_cache_checks=') == 1
    extra = '''    if (dut.hit_n0 !== control.hit_n0 || dut.hit_n1 !== control.hit_n1 ||
        dut.hit_way_n !== control.hit_way_n || dut.addr_n !== control.addr_n)
      $fatal(1,"PARALLEL-NEXT-CACHE-MISMATCH next-line identity/hit");
    if (rst_n) begin
      next_hit_samples += (dut.hit_n0 || dut.hit_n1);
      next_owner_samples += dut.mc_lookup_next;
      next_crossline_samples += dut.xline;
    end
'''
    declarations = '''  integer next_hit_samples=0, next_owner_samples=0, next_crossline_samples=0;
  final begin
    if (next_hit_samples==0 || next_owner_samples==0 || next_crossline_samples==0)
      $error("PARALLEL-NEXT-CACHE-VACUOUS");
    $display("PARALLEL-NEXT-CACHE-COVERAGE hit=%0d owner=%0d crossing=%0d",
             next_hit_samples,next_owner_samples,next_crossline_samples);
  end
'''
    candidate = text.replace(anchor, extra+anchor).replace(
        '  integer parallel_cache_checks=', declarations+'  integer parallel_cache_checks=')
    assert candidate.replace(extra, '').replace(declarations, '') == text
    return candidate


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    data = scratch/'ventium-data-size.v2HaTO2X'
    root = args.out.resolve()
    assert __debug__ and root.is_relative_to(data) and root != data and not root.exists()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert scratch.stat().st_dev != REPO.stat().st_dev and shutil.disk_usage(scratch).free > 5*1024**3
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    assert os.environ['VENTIUM_BUILD_SCOPE_UNIT'] == 'ventium-ipc-parallel32'
    assert os.environ['VENTIUM_VERILATOR_BIN'] == '/tools/verilator/v5.046/bin/verilator'
    subprocess.run([REPO/'tools/build_scope.sh','--is-active'],check=True,pass_fds=(9,))
    assert subprocess.run(['pgrep','-x','vivado'],stdout=subprocess.DEVNULL).returncode == 1
    subprocess.run(['systemctl','--user','set-property','--runtime','ventium-ipc-parallel32.scope',
                    'MemoryMax=10G','MemorySwapMax=2G'],check=True)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    load = lambda p: json.loads(p.read_text())
    prior, leaf = data/'window-current-cache-r1', data/'parallel-next-tag-leaf-r1'
    assert sha(prior/'closed.json') == PARENT and sha(leaf/'closed.json') == LEAF
    checked, old = load(leaf/'closed.json'), load(prior/'closed.json')
    assert checked['passed'] and checked['pins_unchanged'] and old['passed'] and old['pins_unchanged']
    assert len(checked['rows']) == 22
    assert all(r['build_exit']==0 and r['run_exit']==(0 if r['name'].startswith('positive-') else 1)
               for r in checked['rows'])
    pins = dict(old['pins']); pins.update(checked['pins'])
    assert all(sha(p)==h for p,h in pins.items())
    source = data/'window-current-core-r1/candidate/rtl/mem/ven_l1d.sv'
    original = source.read_text()
    changed = recipe.transform(original)
    assert changed == (leaf/'proposal.sv').read_text()
    fixture = prior/'tb_l1d_mem_chain.sv'
    assert sha(fixture)==FIXTURE and sha(prior/'positive/ven_l1d.sv')==recipe.PARENT
    root.mkdir()
    (root/'control_l1d.sv').write_text(control_source(original))
    (root/'tb_l1d_mem_chain.sv').write_text(bench(fixture.read_text()))
    for p in (Path(__file__).resolve(),Path(recipe.__file__).resolve(),source,fixture,
              root/'control_l1d.sv',root/'tb_l1d_mem_chain.sv',prior/'closed.json',leaf/'closed.json',
              REPO/'verif/l1/run_parallel_tag_cache.py',REPO/'verif/l1/test_parallel_next_cache.py'):
        pins[str(p)]=sha(p)
    def save(name,value):
        with (root/name).open('x') as stream: json.dump(value,stream,indent=2)
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        controller_affinity=sorted(os.sched_getaffinity(0)),whole_core=False,gameplay_ipc=None))
    begin=time.monotonic()
    result=dict(passed=False,rows=[],error=None,whole_core=False,gameplay_ipc=None,
                timing_mhz=None,standard_suite=False,hardware_acceptance=False)
    try:
        for mutant in (False,True):
            folder=root/('wrong-stride' if mutant else 'positive'); folder.mkdir()
            sv=folder/'ven_l1d.sv'
            sv.write_text(changed.replace("tag_current_next_addr = c_addr + 32'd32;",
                "tag_current_next_addr = c_addr + 32'd16;") if mutant else changed)
            # Only relocate generated files. Preserve all defines, six hard
            # structural errors, all helper module sources and 32 compile jobs.
            command=[s.replace(str(prior),str(root)).replace(str(root/'positive'),str(folder))
                     for s in old['rows'][0]['command']]
            assert command[command.index('-j')+1]=='32'
            assert sum(s.startswith('+define+') for s in command)==152
            row=dict(mutant=mutant,command=command); result['rows'].append(row)
            with (folder/'build.log').open('x') as stream:
                native=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,
                    env=dict(os.environ,CCACHE_DISABLE='1'),pass_fds=(9,),timeout=180)
            row['build_exit']=native.returncode
            assert native.returncode==0
            with (folder/'run.log').open('x') as stream:
                native=subprocess.run([folder/'obj/test','+OBS='+str(folder/'cycles.txt')],
                    stdout=stream,stderr=subprocess.STDOUT,timeout=40)
            row['native_exit']=native.returncode
            log=(folder/'run.log').read_text()
            if mutant:
                assert native.returncode != 0 and 'PARALLEL-NEXT-CACHE-MISMATCH' in log
            else:
                assert native.returncode==0 and not re.search(r'%Error|%Fatal|FATAL|FAIL|MISMATCH|VACUOUS',log)
                for marker in ('L1D-MEM-CHAIN-OK accepted=150','WINDOW-WRITE-UPDATE-OK',
                    'STORE-WARM-OK','RESPONSE-PAYLOAD-OK','HIGH-WINDOW-PAYLOAD-OK',
                    'FRESH-PAIR-CACHE-OK cases=51 pairs=41 held=123 saved=2 conflicts=8 guards=4',
                    'PARALLEL-CACHE-MITER checks=747037 next=463'):
                    assert marker in log,marker
                coverage=re.findall(r'^PARALLEL-NEXT-CACHE-COVERAGE hit=(\d+) owner=(\d+) crossing=(\d+)$',log,re.M)
                assert len(coverage)==1 and all(int(v)>0 for v in coverage[0])
                row['coverage']=dict(zip(('hit','owner','crossing'),map(int,coverage[0])))
            row['artifacts']={str(p):sha(p) for p in (sv,folder/'obj/test',folder/'build.log',
                                                     folder/'run.log',folder/'cycles.txt')}
            print(json.dumps({k:v for k,v in row.items() if k not in ('command','artifacts')}),flush=True)
        result['passed']=True
    except Exception as exc:
        result['error']=repr(exc)
    group=Path('/sys/fs/cgroup')/Path('/proc/self/cgroup').read_text().split('::',1)[1].strip().lstrip('/')
    events=dict(line.split() for line in (group/'memory.events').read_text().splitlines())
    no_oom=all(events[k]=='0' for k in ('oom','oom_kill','oom_group_kill'))
    result.update(seconds=time.monotonic()-begin,pins=pins,
        pins_unchanged=all(sha(p)==h for p,h in pins.items()),memory_events=events,no_oom=no_oom,
        memory_peak=int((group/'memory.peak').read_text()),swap=int((group/'memory.swap.current').read_text()))
    result['passed'] &= result['pins_unchanged'] and no_oom
    save('closed.json',result)
    print(json.dumps({k:v for k,v in result.items() if k not in ('pins','rows')}),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
