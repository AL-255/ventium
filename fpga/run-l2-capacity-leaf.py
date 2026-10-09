#!/usr/bin/env python3
"""Bounded physical check of a functionally tested, parameterized platform L2."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
SCRATCH = Path('/home/yukidama/external/tmp')
SCOPE = 'ventium-vivado.scope'
GIB = 1024**3


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def state():
    text = subprocess.check_output(['systemctl', '--user', 'show', SCOPE,
        '-p', 'ActiveState', '-p', 'InvocationID', '-p', 'ControlGroup',
        '-p', 'MemoryMax', '-p', 'MemorySwapMax'], text=True, timeout=5)
    return dict(line.split('=', 1) for line in text.splitlines())


def available():
    return int(next(s.split()[1] for s in Path('/proc/meminfo').read_text().splitlines()
                    if s.startswith('MemAvailable:'))) * 1024


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--leaf-result', type=Path, required=True)
    args = ap.parse_args()
    assert __debug__ and state()['ActiveState'] in ('inactive', 'failed')
    names = subprocess.check_output(['ps', '-eo', 'comm='], text=True).splitlines()
    assert not any(n.strip().lower() in ('vivado', 'vrs') for n in names)
    assert SCRATCH.resolve() == Path(os.environ['TMPDIR']).resolve()
    assert available() > 10*GIB and shutil.disk_usage(SCRATCH).free > 4*GIB
    leaf = args.leaf_result.resolve(strict=True)
    result = json.loads((leaf/'closed.json').read_text())
    assert result['passed'] and result['stable_inputs'] and result['xpm_fidelity']
    assert result['lru_repaired'] and result['lru_owner_assertions'] and result['lru_write_owner_assertions']
    assert not result['unsafe_read_only'] and not result['unsafe_no_forward']
    assert result['stream_profile'] == 'any'
    assert all(sha(p) == h for p, h in result['source_pins'].items())
    assert all(sha(p) == h for p, h in result['frozen_script_pins'].items())
    expected = {(s, l, n, w, g) for s in (128, 256, 512, 1024)
                for l in (512, 1024, 2048, 4096) for n in (1, 2)
                for w in range(1, 9) for g in (0, 1)}
    actual = {(r['sets'], r['lines'], r['seed'], r['words'], r['gap']) for r in result['rows']}
    assert actual == expected and len(result['rows']) == len(expected)
    recipe = leaf/'scripts/prepare_l2_capacity.py'
    spec = importlib.util.spec_from_file_location('capacity_recipe', recipe)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    assert (leaf/'candidate.v').read_text() == module.transform((leaf/'control.v').read_text())
    root = Path(tempfile.mkdtemp(prefix='ventium-l2-capacity-physical.', dir=SCRATCH)).resolve()
    inputs = root/'inputs'; inputs.mkdir(); (root/'tmp').mkdir()
    sources = {name: leaf/name for name in ('control.v', 'candidate.v', 'prims.sv')}
    sources['inspect.tcl'] = REPO/'fpga/inspect_l2_capacity_leaf.tcl'
    pins = {str(p): sha(p) for p in (Path(__file__).resolve(), leaf/'closed.json', recipe,
        REPO/'fpga/run_vivado_exclusive.sh', REPO/'tools/build_scope.sh')}
    for name, source in sources.items():
        target = inputs/name; shutil.copyfile(source, target)
        pins[str(source)] = sha(source); pins[str(target)] = sha(target)
        assert pins[str(source)] == pins[str(target)]
    save(root/'inputs.json', pins)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VENTIUM_', 'VEN_', 'AXI_', 'TB_'))}
    env.update(TMPDIR=str(root/'tmp'), PYTHONDONTWRITEBYTECODE='1',
        VENTIUM_VIVADO_LOCK_DIR=str(SCRATCH), VENTIUM_VIVADO_MEMORY_MAX='8G',
        VENTIUM_VIVADO_MEMORY_SWAP_MAX='0')
    script = inputs/'inspect.tcl'
    command = ['timeout', '--signal=TERM', '--kill-after=15s', '600s',
        str(REPO/'fpga/run_vivado_exclusive.sh'), '-mode', 'batch', '-source', str(script),
        '-log', str(root/'native.log'), '-journal', str(root/'native.jou'),
        '-tclargs', str(inputs), str(root/'reports')]
    save(root/'command.json', command); print(root, flush=True)
    owner = None; peak = 0; reason = None; failure = None; events = {}; start = time.monotonic()
    def stop_owned():
        now = state()
        if owner and now['ActiveState'] == 'active' and now['InvocationID'] == owner['InvocationID']:
            subprocess.run(['systemctl', '--user', 'kill', '--kill-whom=all', '--signal=TERM', SCOPE],
                           check=True, timeout=5)
    with (root/'guard.log').open('x') as log:
        proc = subprocess.Popen(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            while proc.poll() is None:
                now = state()
                if now['ActiveState'] == 'active':
                    cg = Path('/sys/fs/cgroup'+now['ControlGroup'])
                    if owner is None:
                        for pid in (cg/'cgroup.procs').read_text().split():
                            try: argv = Path('/proc/'+pid+'/cmdline').read_bytes().split(b'\0')
                            except FileNotFoundError: continue
                            if str(script).encode() in argv:
                                assert now['MemoryMax'] == str(8*GIB) and now['MemorySwapMax'] == '0'
                                owner = now; break
                    if owner:
                        assert now['InvocationID'] == owner['InvocationID']
                        try:
                            used = int((cg/'memory.current').read_text())
                            events = {k:int(v) for k,v in (line.split() for line in (cg/'memory.events').read_text().splitlines())}
                        except FileNotFoundError: continue
                        peak = max(peak, used)
                        if used >= 7*GIB or available() < 2*GIB or shutil.disk_usage(root).free < 2*GIB or events.get('oom', 0):
                            reason = 'resource reserve'; stop_owned(); break
                time.sleep(.5)
        except BaseException as exc:
            failure = repr(exc); stop_owned()
        finally:
            try: rc = proc.wait(timeout=630)
            except subprocess.TimeoutExpired:
                stop_owned(); proc.terminate(); rc = proc.wait(timeout=30); failure = 'wrapper wait timeout'
    stable = all(sha(p) == h for p, h in pins.items())
    closed = dict(native_exit=rc, owner=owner, peak_bytes=peak, resource_stop=reason,
        oom_events=events, inputs_unchanged=stable, controller_failure=failure,
        wall_seconds=time.monotonic()-start, cpu_fmax_qualified=False, gameplay_ipc=None, standard_suite=False)
    save(root/'closed.json', closed)
    assert rc == 0 and owner and reason is None and failure is None and stable and not events.get('oom', 0)
    assert state()['ActiveState'] in ('inactive', 'failed')
    report = (root/'reports/receipt.tsv').read_text()
    assert report.count('\n') == 5 and 'COMPLETE CPU_FMAX_QUALIFIED=0 STANDARD_SUITE=0' in report
    print(report, flush=True)


if __name__ == '__main__':
    main()
