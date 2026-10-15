"""Finish the already-running synthesis, then its prepared read-only clock audit.

One fixed invocation, not a retry loop. Never starts synthesis, implementation,
or deployment. A failed/changed owner stops this sequencer without relaunching.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)
SYNTH = 'ventium-decode-bus-synth-oct15-r1.service'
SYNTH_INVOCATION = '26931169bdb9480fa5bc8264a68a4ed8'
CLOCK = 'ventium-decode-bus-clock-oct15-r1.service'
CHAIN = 'ventium-decode-bus-timing-chain-oct15-r1.service'
MANIFEST = '36908a9d96c4ddca51d143f634acacc85c067bfeb1aaf24833a9eda99fb6a7dc'
MODEL = '7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def props(unit):
    command = ['systemctl', '--user', 'show', unit, '-p', 'LoadState', '-p', 'SubState',
               '-p', 'MainPID', '-p', 'InvocationID', '-p', 'ExecMainStatus', '-p', 'Result']
    return dict(line.split('=', 1) for line in subprocess.check_output(
        command, text=True, timeout=5).splitlines())


def save(name, value):
    with (ROOT/name).open('x') as stream:
        json.dump(value, stream, indent=2)


def wait_closed(unit, invocation, deadline, watch):
    while True:
        state = props(unit)
        require(state['InvocationID'] == invocation, 'owner changed: ' + unit)
        if state['MainPID'] == '0':
            require(state['SubState'] == 'exited' and state['ExecMainStatus'] == '0' and
                    state['Result'] == 'success', 'owner failed: ' + repr(state))
            return state
        require(state['SubState'] == 'running', 'unexpected owner phase: ' + repr(state))
        # Confirm an actual process, not merely a nonterminal metadata file.
        task = Path('/proc')/state['MainPID']
        try:
            process = dict(stat=task.joinpath('stat').read_text(),
                           cmdline=task.joinpath('cmdline').read_bytes().decode().split('\0'),
                           cgroup=task.joinpath('cgroup').read_text())
        except FileNotFoundError:
            continue  # Process exit raced observation; re-read this exact owner.
        watch.write(json.dumps(dict(unix=time.time(), unit=unit, owner=state, process=process))+'\n')
        watch.flush()
        require(time.monotonic() < deadline, 'sequencer observation deadline; no restart')
        time.sleep(10)


def main():
    require(Path(os.environ['TMPDIR']).resolve() == ROOT.parent, 'external TMPDIR required')
    require(props(CHAIN)['MainPID'] == str(os.getpid()) and
            props(CHAIN)['InvocationID'] == os.environ['INVOCATION_ID'], 'wrong sequence owner')
    require(props(SYNTH)['InvocationID'] == SYNTH_INVOCATION, 'wrong synthesis owner')
    require(props(CLOCK)['LoadState'] == 'not-found', 'clock owner already exists; refuse duplicate')
    require(not (ROOT/'decode-bus-clock-r1/started.json').exists(), 'clock already started')
    require(not (ROOT/'decode-bus-synthesis-r1/audit.json').exists(), 'synthesis already audited')
    prepared = json.loads((ROOT/'decode-bus-timing-prepared.json').read_text())
    pins = prepared['outputs']
    require(all(sha(path) == digest for path, digest in pins.items()), 'prepared controller drift')
    deadline = time.monotonic()+3600
    start = dict(invocation=os.environ['INVOCATION_ID'], synth_invocation=SYNTH_INVOCATION,
                 pins=pins, script_sha256=sha(__file__), model=MODEL, manifest=MANIFEST,
                 no_synthesis_or_implementation_launch=True, unix=time.time())
    save('decode-bus-sequence-started.json', start)
    result = dict(passed=False, synthesis=None, clock=None, error=None)
    try:
        with (ROOT/'decode-bus-sequence-watch.jsonl').open('x') as watch:
            result['synthesis'] = wait_closed(SYNTH, SYNTH_INVOCATION, deadline, watch)
            subprocess.run(['/usr/bin/python3', '-B', str(ROOT/'decode-bus-synthesis-r1/audit_closed.py')],
                           check=True, timeout=120)
            require(all(sha(path) == digest for path, digest in pins.items()), 'controller drift after synth')
            subprocess.run(['systemd-run', '--user', '--unit='+CLOCK,
                '-p', 'Type=exec', '-p', 'RemainAfterExit=yes', '-p', 'MemoryMax=1G',
                '-p', 'MemorySwapMax=0', '-p', 'TasksMax=256', '-p', 'RuntimeMaxSec=1200',
                '-p', 'KillMode=control-group', '--working-directory=/home/yukidama/github/ventium',
                '--setenv=TMPDIR=/home/yukidama/external/tmp', '--setenv=PYTHONDONTWRITEBYTECODE=1',
                '/usr/bin/taskset', '-c', '24-27', '/usr/bin/python3', '-B',
                str(ROOT/'decode-bus-clock-r1/run.py'), '--manifest-sha256', MANIFEST,
                '--model-sha256', MODEL], check=True, timeout=15)
            owner = props(CLOCK)
            require(owner['LoadState'] == 'loaded' and len(owner['InvocationID']) == 32,
                    'clock owner not admitted')
            save('decode-bus-sequence-clock-owner.json', owner)
            result['clock'] = wait_closed(CLOCK, owner['InvocationID'], deadline, watch)
            subprocess.run(['/usr/bin/python3', '-B', str(ROOT/'decode-bus-clock-r1/audit_closed.py')],
                           check=True, timeout=120)
            require(all(sha(path) == digest for path, digest in pins.items()), 'controller drift after audit')
            result['passed'] = True
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        result['error'] = repr(exc)
    save('decode-bus-sequence-closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
