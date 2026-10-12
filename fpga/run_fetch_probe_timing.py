#!/usr/bin/env python3
"""Adopt one fetch-probe synthesis; audit it, then measure its native timing.

Never starts/restarts synthesis, routes or programs hardware. Audit-process
success and the actual >=40 MHz requirement remain distinct.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

from prepare_fetch_probe_synthesis import PARENT as ROOT, MANIFEST, MODEL


def sha(p):
    with Path(p).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()


def load(p): return json.loads(p.read_text())


def state(unit):
    return dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
        '-p','LoadState','-p','SubState','-p','InvocationID','-p','MainPID','-p','ExecMainStatus'],
        text=True,timeout=10).splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synth-invocation',required=True)
    invocation = parser.parse_args().synth_invocation
    assert re.fullmatch('[0-9a-f]{32}',invocation)
    assert __debug__ and os.environ['TMPDIR'] == '/home/yukidama/external/tmp'
    prepared = load(ROOT/'probe-timing-prepared.json')
    assert prepared['source_manifest_sha256'] == MANIFEST and prepared['model_sha256'] == MODEL
    assert prepared['unchanged_guard_lifecycle'] and prepared['controllers_generated_not_launched']
    pins = {**prepared['outputs'],**prepared['template_pins'],str(Path(__file__)):sha(__file__)}
    pins[str(ROOT/'probe-timing-prepared.json')] = sha(ROOT/'probe-timing-prepared.json')
    assert all(sha(p) == h for p,h in pins.items())
    synth = 'ventium-fetch-probe-synth-oct12.service'
    current = state(synth)
    assert current['LoadState'] == 'loaded' and current['InvocationID'] == invocation
    assert load(ROOT/'probe-synthesis-r1/started.json')['controller_invocation'] == invocation
    out = ROOT/'probe-timing-queue-r1'; out.mkdir()
    def save(name,value):
        with (out/name).open('x') as f: json.dump(value,f,indent=2)
    owners = {'synthesis':dict(unit=synth,invocation=invocation)}
    save('started.json',dict(pins=pins,invocation=os.environ['INVOCATION_ID'],
        adopted_synthesis=current,source_manifest_sha256=MANIFEST,model_sha256=MODEL))

    def close(phase,seconds):
        owner = owners[phase]; deadline = time.monotonic()+seconds
        while True:
            actual = state(owner['unit'])
            assert actual['LoadState'] == 'loaded' and actual['InvocationID'] == owner['invocation'], actual
            if actual['MainPID'] == '0' and actual['SubState'] in ('exited','failed','dead'): break
            assert time.monotonic() < deadline, actual
            time.sleep(5)
        save(phase+'-owner-closed.json',actual)
        assert actual['SubState'] == 'exited' and actual['ExecMainStatus'] == '0', actual
        folder = ROOT/('probe-'+phase+'-r1'); closed = load(folder/'closed.json')
        assert closed['native_exit'] == 0 and closed['inputs_unchanged']
        assert closed['resource_stop'] is None and closed['controller_failure'] is None
        assert all(sha(p) == h for p,h in pins.items())
        with (out/(phase+'-audit.log')).open('x') as stream:
            subprocess.run(['/usr/bin/python3','-B',str(folder/'audit_closed.py')],
                check=True,stdout=stream,stderr=subprocess.STDOUT,timeout=180)
        assert load(folder/'audit.json')['passed']

    begin = time.monotonic()
    try:
        close('synthesis',3100)
        clock = 'ventium-fetch-probe-clock-oct12.service'
        assert state(clock)['LoadState'] == 'not-found', 'existing clock owner; do not restart'
        command = ['systemd-run','--user','--unit='+clock,'--property=Type=exec',
            '--property=RemainAfterExit=yes','--property=MemoryMax=768M','--property=MemorySwapMax=0',
            '--property=TasksMax=128','--property=RuntimeMaxSec=1100',
            '--setenv=TMPDIR=/home/yukidama/external/tmp','--setenv=PYTHONDONTWRITEBYTECODE=1',
            '/usr/bin/python3','-B',str(ROOT/'probe-clock-r1/run.py'),
            '--manifest-sha256',MANIFEST,'--model-sha256',MODEL]
        subprocess.run(command,check=True,timeout=20)
        actual = state(clock)
        assert actual['LoadState'] == 'loaded' and len(actual['InvocationID']) == 32
        owners['clock'] = dict(unit=clock,invocation=actual['InvocationID'])
        save('clock-started.json',dict(command=command,**owners['clock']))
        close('clock',1220)
        audit = load(ROOT/'probe-clock-r1/audit.json')
        result = dict(passed=True,owners=owners,seconds=time.monotonic()-begin,
            synthesized_fmax_mhz=audit['unplaced_core_estimate_mhz'],
            synthesized_40mhz_requirement_met=audit['unplaced_core_estimate_mhz'] >= 40,
            worst_setup_ns=audit['worst_setup_ns'],worst_hold_ns=audit['worst_hold_ns'],
            canonical_gate_passed=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None)
        assert all(sha(p) == h for p,h in pins.items())
    except BaseException as error:
        save('closed.json',dict(passed=False,owners=owners,seconds=time.monotonic()-begin,error=repr(error)))
        raise
    save('closed.json',result)
    print(json.dumps(result),flush=True)


if __name__ == '__main__': main()
