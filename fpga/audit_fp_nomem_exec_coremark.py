"""Independently close both unchanged short seeds; no valid score or suite claim."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--soc', type=Path, required=True)
parser.add_argument('--unit', required=True)
args = parser.parse_args()
soc = args.soc.resolve(strict=True)
scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
assert soc.is_relative_to(scratch)
root = soc / 'coremark'
parent = scratch / 'ventium-l1-capture-soc.NLtK13lC'
repo = Path('/home/yukidama/github/ventium')
sys.path.insert(0, str(repo/'verif/bench/coremark_boot'))
from check_result import check

def load(p):
    return json.loads(p.read_text())

def sha(p):
    with Path(p).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

assert __debug__
start, closed = load(root/'started.json'), load(root/'closed.json')
assert start['model'] == load(soc/'build-closed.json')['binary_sha256']
assert closed['passed'] and closed['pins_unchanged'] and closed['all_children_reaped']
assert all(sha(p) == h for p,h in start['pins'].items())
assert not closed['score_eligible'] and not closed['standard_suite']
assert closed['gameplay_ipc'] is None
assert all(closed['memory_events'][k] == '0' for k in ('oom','oom_kill','oom_group_kill'))
unit = args.unit
keys = ('ActiveState','SubState','MainPID','ExecMainCode','ExecMainStatus','InvocationID','Result','ControlGroup','MemoryPeak')
owner = dict(x.split('=',1) for x in subprocess.check_output([
    'systemctl','--user','show',unit,*['-p'+k for k in keys]],text=True).splitlines())
assert owner['InvocationID'] == start['invocation']
assert {k: owner[k] for k in keys[:5]} == dict(ActiveState='active',SubState='exited',MainPID='0',ExecMainCode='1',ExecMainStatus='0')
assert owner['Result'] == 'success'
if owner['ControlGroup']:
    cg = Path('/sys/fs/cgroup')/owner['ControlGroup'].lstrip('/')
    assert not (cg/'cgroup.procs').read_text().strip()
boot = scratch/'ventium-coremark-boot.z4ICVy4Y/smoke-r2'
rom = scratch/'ventium-sfetch16-soc.p8u2t1lA/quake-cold-sfetch16-oct10.1/run/rom'
prior = load(parent/'coremark/closed.json')
assert prior['passed'] and load(parent/'coremark/audit.json')['passed']
assert [x['seed'] for x in closed['results']] == ['performance','validation']
rows, artifacts = [], {}
for item in closed['results']:
    seed = item['seed']
    work = root/seed
    assert sha(work/'run.log') == item['log_sha256'] and item['native_exit'] == 0
    native = load(work/'native.json')
    assert native == load(work/'native-observed.json')
    assert not (Path('/proc')/str(native['pid'])).exists()
    assert load(work/'native-closure.json') == dict(native_exit=0,actual_wait=True,pid=native['pid'],proc_gone=True)
    assert native['cgroup'].strip().endswith('/'+unit)
    assert native['affinity'] == [11] and native['bios_dir'] == str(work/'rom')
    assert native['exe'] == str(soc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')
    assert sha(native['exe']) == start['model']
    argv = [native['exe'],'--ide',str(work/'coremark.img'),'--rate','40000000',
        '--rate-rtc','40000000','--rate-vga','80000000','--mem','16','--cycles','13000000',
        '--ven-perf-every','1000000','--vgatext-every','1000000']
    assert native['argv'] == argv
    assert sha(work/'coremark.img') == sha(boot/seed/'coremark.img')
    assert all(sha(work/'rom'/n) == sha(rom/n) for n in ('boot0.rom','boot1.rom'))
    log = (work/'run.log').read_text()
    assert not re.search(r'cannot open|%Error|%Fatal|Assertion failed|CPU HUNG|UNIMPLEMENTED',log)
    assert '[BOARD_AXI] real RTL profile=1 slots=16 B-delay=20 R-first=21 gap=1' in log
    screens = []
    for chunk in re.split(r'\[VGATEXT @',log)[1:]:
        screen = '\n'.join(x[3:] for x in chunk.splitlines() if x.startswith('  |'))
        if 'PORT-END' in screen:
            screens.append(screen)
    assert screens and all(s == screens[0] for s in screens)
    crcs = {'performance':['e9f5','e714','1fd7','8e3a','fcaf'],
            'validation':['18f2','e3c1','0747','8d84','c64e']}[seed]
    result = check(screens[0],reference_crcs=crcs,iterations=10,require_valid_duration=False)
    ref = check((boot/seed/'qemu-debug.log').read_text(),reference_crcs=crcs,iterations=10,require_valid_duration=False)
    assert ref['crcs'] == result['crcs'] == item['crcs']
    old = next(x for x in prior['results'] if x['seed'] == seed)
    assert old['ticks'] == result['ticks'] == item['ticks']
    samples = re.findall(r'\[VEN-PERF\] cycle=(\d+) retires=(\d+) clocks=(\d+) u=(\d+) v=(\d+)',log)
    assert samples and int(samples[-1][4]) == item['last_v'] > 0
    assert int(samples[-1][3]) == item['last_u']
    for name in ('run.log','native.json','native-observed.json','native-closure.json','result.json'):
        artifacts[str(work/name)] = sha(work/name)
    rows.append(dict(seed=seed,crcs=crcs,parent_ticks=old['ticks'],candidate_ticks=result['ticks'],
        throughput_gain_percent=0,actual_v=int(samples[-1][4]),duration_valid=False))
for p in (Path(__file__),root/'started.json',root/'closed.json',parent/'coremark/closed.json',parent/'coremark/audit.json'):
    artifacts[str(p)] = sha(p)
result = dict(passed=True,model=start['model'],measurements=rows,retained_owner=owner,
    artifact_pins=artifacts,source_pins_rechecked=len(start['pins']),no_oom=True,
    all_children_reaped=True,duration_valid=False,standard_suite=False,physical_board=False,gameplay_ipc=None)
with (root/'audit.json').open('x') as f:
    json.dump(result,f,indent=2)
print(json.dumps({k:v for k,v in result.items() if k != 'artifact_pins'},indent=2))
