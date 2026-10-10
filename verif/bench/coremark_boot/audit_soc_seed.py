#!/usr/bin/env python3
"""Independently close one completed duration-valid SoC seed; never a board pass."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

from check_result import check


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f,'sha256').hexdigest()


def audit(root,unit,model_sha):
    assert __debug__ and re.fullmatch('[0-9a-f]{64}',model_sha)
    root = root.resolve(strict=True)
    assert root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    started = json.loads((root/'started.json').read_text())
    closed = json.loads((root/'closed.json').read_text())
    native = json.loads((root/'native.json').read_text())
    assert closed['passed'] and closed['error'] is None and closed['native_exit'] == 0
    assert closed['pins_unchanged'] and closed['pipe_eof'] and closed['all_children_reaped']
    assert closed['seconds'] <= started['wall_seconds_cap']+10 <= 3610
    assert closed['native'] == native and native['argv'] == started['argv']
    assert native['affinity'] == [started['cpu']]
    assert not (Path('/proc')/str(native['pid'])).exists(), 'native PID still exists'
    assert sha(native['exe']) == started['model_sha256'] == model_sha
    argv = started['argv']
    assert argv[0] == native['exe'] and len(argv) == 19
    options = dict(zip(argv[1::2],argv[2::2]))
    assert options == {'--ide':str(root/'coremark.img'),'--rate':'40000000',
        '--rate-rtc':'40000000','--rate-vga':'80000000','--mem':'16',
        '--cycles':'450000000','--ven-perf-every':'1000000',
        '--vgatext-every':'1000000','--stop-request':str(root/'stop.request')}
    assert started['cold_reset'] and not started['snapshots'] and not started['guest_modifications']
    assert closed['memory_events']['oom'] == closed['memory_events']['oom_kill'] == '0'
    owner = dict(x.split('=',1) for x in subprocess.check_output(
        ['systemctl','--user','show',unit,'-p','ActiveState','-p','SubState','-p','Result',
         '-p','ExecMainStatus','-p','InvocationID','-p','MainPID'],text=True,timeout=5).splitlines())
    assert owner == dict(ActiveState='active',SubState='exited',Result='success',
        ExecMainStatus='0',InvocationID=started['invocation'],MainPID='0'), owner
    assert closed['invocation'] == started['invocation']
    assert all(sha(p) == h for p,h in started['pins'].items())
    assert sha(Path(__file__).with_name('check_result.py')) == started['pins'][str(
        Path(__file__).resolve().with_name('check_result.py'))]
    reference = started['reference']
    assert reference['native_exit'] == 33 and reference['iterations'] == 900
    assert sha(root/'coremark.img') == reference['disk_sha256']
    for name in ('boot0.rom','boot1.rom'):
        hashes = {h for p,h in started['pins'].items() if Path(p).name == name}
        assert len(hashes) == 1 and sha(root/'rom'/name) in hashes
    data = (root/'run.log').read_bytes()
    assert len(data) == closed['captured_bytes'] and sha(root/'run.log') == closed['captured_sha256']
    assert data.endswith(b'\n')
    text = data.decode('utf-8')
    assert not re.search(r'cannot open|%Error|%Fatal|Assertion failed|CPU HUNG|UNIMPLEMENTED|HOST-STOP-ERROR',text)
    # Independently partition complete VGA snapshots; incomplete boot screens
    # cannot contribute a result assembled across observation times.
    complete = []
    for screen in re.split(r'^\[VGATEXT @[^\n]+\n',text,flags=re.M)[1:]:
        lines=[]
        for line in screen.splitlines():
            if not line.startswith('  |'): break
            lines.append(line[3:])
        if 'PORT-END' in lines:
            end=lines.index('PORT-END')
            complete.append('\n'.join(lines[:end+1]))
    assert complete and all(s == complete[0] for s in complete)
    result = check(complete[0],reference_crcs=reference['crcs'],iterations=900,
                   require_valid_duration=True)
    assert result == closed['result']
    counters=re.findall(r'^\[VEN-PERF\] cycle=(\d+) retires=(\d+) clocks=(\d+) u=(\d+) v=(\d+)',text,re.M)
    assert counters
    c,ret,clocks,u,v=map(int,counters[-1])
    assert ret==u+v and u==closed['last_u'] and v==closed['last_v'] and u>0 and v>0
    assert (root/'stop.request').is_file() and (root/'stop.request').stat().st_size == 0
    return dict(passed=True,seed=started['seed'],model_sha256=model_sha,
        iterations=result['iterations'],ticks=result['ticks'],crcs=result['crcs'],
        coremark_per_mhz=result['diagnostic_ratio'],duration_valid=True,
        actual_guest_seconds=result['ticks']/40000000,native_exit=0,native_reaped=True,
        source_pins_rechecked=len(started['pins']),supervisor=owner,
        complete_console=complete[0],log_sha256=sha(root/'run.log'),
        closure_sha256=sha(root/'closed.json'),auditor_sha256=sha(Path(__file__)),
        current_gameplay_ipc=None,physical_board=False,standard_suite=False,
        scope='One CoreMark seed only; no Win95, Quake or FPGA acceptance.')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--run',type=Path,required=True)
    ap.add_argument('--unit',required=True)
    ap.add_argument('--model-sha256',required=True)
    ap.add_argument('--publish',action='store_true')
    args=ap.parse_args()
    result=audit(args.run,args.unit,args.model_sha256)
    if args.publish:
        with (args.run/'audit.json').open('x') as f:json.dump(result,f,indent=2)
    print(json.dumps(result,indent=2))


if __name__ == '__main__':main()
