"""Bounded observer of one already launched clock-only CAD owner."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time


def properties(unit, names):
    command = ['systemctl', '--user', 'show', unit]
    for name in names: command += ['-p', name]
    return dict(line.split('=', 1) for line in subprocess.check_output(command, text=True).splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('unit')
    parser.add_argument('invocation')
    parser.add_argument('out', type=Path)
    args = parser.parse_args()
    if not args.unit.startswith('ventium-core-clock-') or args.out.exists():
        raise ValueError('require clock-only owner and fresh log')
    started = time.monotonic()
    with args.out.open('x') as stream:
        while True:
            owner = properties(args.unit, ['InvocationID', 'MainPID', 'SubState', 'ExecMainStatus'])
            if owner['InvocationID'] != args.invocation: raise ValueError('owner changed')
            state = dict(owner=owner, elapsed=time.monotonic()-started,
                         free_bytes=shutil.disk_usage(args.out.parent).free)
            scope = properties('ventium-vivado.scope', ['ControlGroup', 'ActiveState'])
            if scope.get('ControlGroup') and scope['ActiveState'] == 'active':
                group = Path('/sys/fs/cgroup'+scope['ControlGroup'])
                try:
                    for name in ('memory.current', 'memory.peak', 'memory.swap.current'):
                        state[name] = int((group/name).read_text())
                    state['events'] = dict(line.split() for line in (group/'memory.events').read_text().splitlines())
                except FileNotFoundError:
                    pass  # Native family closed between the two read-only queries.
            reason = None
            if state.get('memory.current', 0) > 11.5*1024**3: reason = 'resident-memory margin'
            if state['free_bytes'] < 4*1024**3: reason = 'disk margin'
            if state['elapsed'] > 950: reason = 'observer duration'
            if reason and owner['MainPID'] != '0':
                state['resource_stop'] = reason
                subprocess.run(['systemctl', '--user', 'stop', '--no-block', 'ventium-vivado.scope'], check=True)
            stream.write(json.dumps(state)+'\n'); stream.flush()
            if owner['MainPID'] == '0': break
            time.sleep(10)


if __name__ == '__main__': main()
