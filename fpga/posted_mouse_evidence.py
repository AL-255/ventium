"""Exact wrapper-only transfer and closed microgate checks, not FPGA acceptance."""
import hashlib
import json
from pathlib import Path
import subprocess

import repair_posted_mouse_wrapper as repair

MANIFEST = 'ab1c791f3f472ec72a0c36628291d3c6d2e78a6a4a1b449a71a06840800ba8e0'
MODEL = 'b6b92dbfde2c6148fde30b5c65cac8217f650f7bbc1a7d4c0bd58fe95f706c9e'
VARIANT = 'v_result_carry_posted_mouse_repaired_unqualified'
WRAPPER_SHA = '15ce730571500f4d4c1b56e144a3457cec7b44838740d0aa7b5017f8544d9043'


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def check(source):
    source = Path(source).resolve(strict=True)
    parent = source.parent/'v-result-carry-fpga-r1'
    proof = source.parent/'posted-mouse-wrapper-micro-r2'
    pins = {}
    def read(path):
        pins[str(path)] = sha(path)
        return json.loads(path.read_text())
    new, old = read(source/'input-manifest.json'), read(parent/'input-manifest.json')
    assert pins[str(source/'input-manifest.json')] == MANIFEST
    assert pins[str(parent/'input-manifest.json')] == repair.PARENT_SHA
    assert new['variant'] == VARIANT and new['qualification'] == 'UNQUALIFIED'
    assert new['processor_platform_simulator_sha256'] == old['processor_platform_simulator_sha256'] == MODEL
    assert new['simulator_sha256'] is None and not new['full_wrapper_elaborated']
    for key in ('hardware_defines','core_mhz','l2_sets','write_slots'):
        assert new[key] == old[key], key
    a = {r['frozen']:r for r in old['files']}; b = {r['frozen']:r for r in new['files']}
    assert len(a) == len(b) == 192 and set(a) == set(b)
    assert [n for n in a if a[n]['sha256'] != b[n]['sha256']] == [repair.WRAPPER]
    for folder, rows in ((source,b), (parent,a)):
        for name,row in rows.items():
            path = folder/name; assert sha(path) == row['sha256']
            pins[str(path)] = row['sha256']
    assert b[repair.WRAPPER]['sha256'] == WRAPPER_SHA
    assert (source/repair.WRAPPER).read_text() == repair.repair((parent/repair.WRAPPER).read_text())
    start, done = read(proof/'started.json'), read(proof/'closed.json')
    assert done['passed'] and done['pins_unchanged'] and done['error'] is None
    assert start['invocation'] == 'b4eeabc049cd4ccf8ceda03c33f015e7'
    assert start['affinity'] == [12,13] and start['unrelated_modules_blackboxed']
    assert not any(done[k] for k in ('full_wrapper_elaboration','processor','windows','physical_board','standard_suite'))
    expected = [(f'{label}-{hz}-posted{int(posted)}', label=='parent' and posted)
        for hz in (3125000,40000000) for posted in (False,True) for label in ('parent','candidate')]
    assert len(done['rows']) == len(expected) == 8
    for row,(name,bad) in zip(done['rows'],expected):
        assert row['name'] == name and row['compile_exit'] == 0
        assert row['native_exit'] == int(bad) and row['expected_old_bug'] == bad
        assert '-i' in row['command']  # Explicitly NOT full-processor verification.
        path = proof/(name+'.native.log'); pins[str(path)] = sha(path)
        marker = 'POSTED-MOUSE-CAPABILITY-MISSING' if bad else 'POSTED-MOUSE-WRAPPER-MICRO-OK'
        assert marker in path.read_text()
    owner = dict(s.split('=',1) for s in subprocess.check_output([
        'systemctl','--user','show','ventium-posted-mouse-wrapper-oct16-r2.service',
        '-p','SubState','-p','MainPID','-p','InvocationID','-p','ExecMainStatus','-p','Result'],text=True).splitlines())
    assert owner == dict(SubState='exited',MainPID='0',InvocationID=start['invocation'],
                         ExecMainStatus='0',Result='success')
    pins.update(start['pins'])
    for path in (Path(__file__).resolve(),Path(repair.__file__).resolve()): pins[str(path)] = sha(path)
    assert all(sha(path) == h for path,h in pins.items())
    return pins
