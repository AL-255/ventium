"""Bounded isolated leaf synthesis; no production synthesis/route/board ops."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

root = Path(__file__).resolve().parent
os.chdir(root)
script = root / 'inspect_pc_paths.tcl'
repo = Path('/home/yukidama/github/ventium')
guard = Path('/home/yukidama/github/ventium/fpga/run_vivado_exclusive.sh')
scope = 'ventium-vivado.scope'
def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()
def available():
    return int(next(x.split()[1] for x in Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemAvailable:'))) * 1024
def scope_info():
    result = subprocess.run(['systemctl', '--user', 'show', scope, '-p', 'ActiveState', '-p', 'InvocationID', '-p', 'ControlGroup', '-p', 'MemoryMax'], capture_output=True, text=True, timeout=3)
    return dict(x.split('=', 1) for x in result.stdout.splitlines() if '=' in x)
assert scope_info().get('ActiveState') in ('inactive', 'failed'), 'do not replace a running query'
assert shutil.disk_usage(root).free > 1000000000 and available() > 10000000000
pin_files = [script, Path(__file__).resolve(), guard, root/'control.sv', root/'repair.sv',
             root/'ven_p54_bank_arb.sv',root/'ven_p54_hit_return.sv',root/'exact110.defines.args.txt']
pins = {str(p): digest(p) for p in pin_files}
with (root / 'inputs.json').open('x') as f: json.dump(pins, f, indent=2)
(root / 'launch.once').mkdir()
(root / 'tmp').mkdir()
env = dict(os.environ, TMPDIR=str(root / 'tmp'), VENTIUM_VIVADO_LOCK_DIR='/home/yukidama/external/tmp', VENTIUM_VIVADO_MEMORY_MAX='8G', VENTIUM_VIVADO_MEMORY_SWAP_MAX='0')
command = ['timeout', '--signal=TERM', '--kill-after=15s', '600s', str(guard), '-mode', 'batch', '-source', str(script), '-log', str(root / 'native.log'), '-journal', str(root / 'native.jou'), '-tclargs', str(root / 'native-output')]
owner = None
peak = 0
reason = None
with (root / 'guard.log').open('x') as out:
    proc = subprocess.Popen(command, stdout=out, stderr=subprocess.STDOUT, env=env)
    while proc.poll() is None:
        info = scope_info()
        if owner is None and info.get('ActiveState') == 'active':
            group = Path('/sys/fs/cgroup' + info['ControlGroup'])
            for pid in (group / 'cgroup.procs').read_text().split():
                try:
                    args = Path('/proc/' + pid + '/cmdline').read_bytes().split(b'\0')
                    owned = str(script).encode() in args
                except FileNotFoundError:
                    continue
                if owned:
                    assert info['MemoryMax'] == str(8 * 1024**3)
                    owner = info
                    print(json.dumps({'event': 'owned', **info}), flush=True)
                    break
        if owner is not None and info.get('ActiveState') == 'active':
            assert info['InvocationID'] == owner['InvocationID'] and info['ControlGroup'] == owner['ControlGroup']
            group = Path('/sys/fs/cgroup' + owner['ControlGroup'])
            try:
                current = int((group / 'memory.current').read_text())
                events = dict((k, int(v)) for k, v in (x.split() for x in (group / 'memory.events').read_text().splitlines()))
            except FileNotFoundError:
                continue
            peak = max(peak, current)
            if current >= 7 * 1024**3 or available() < 2 * 1024**3 or events.get('oom', 0) or events.get('oom_kill', 0):
                reason = 'resource_stop'
                subprocess.run(['systemctl', '--user', 'kill', '--kill-whom=all', '--signal=TERM', scope], check=True, timeout=5)
                break
        time.sleep(.25)
    status = proc.wait(timeout=630)
pin_ok = pins == {p: digest(Path(p)) for p in pins}
result = dict(native_exit=status, pins_unchanged=pin_ok, peak_bytes=peak, resource_stop=reason, owner=owner, cpu_acceptance=False)
with (root / 'closed.json').open('x') as f: json.dump(result, f, indent=2)
print(json.dumps(result), flush=True)
assert status == 0 and pin_ok and reason is None and owner is not None
