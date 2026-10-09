#!/usr/bin/env python3
"""Retain live transient unit identities until their actual closure is archived.

systemd garbage-collects successful transient units. Keep one D-Bus RefUnit
per expected invocation until its inactive/failed properties have been saved;
then immediately release it. This changes only manager metadata lifetime, not
guest state, runtime limits, scheduling, stop policy or acceptance decisions.
Run with the system Python providing python3-dbus. No run is launched/stopped.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time


def query(unit):
    keys = ('ActiveState', 'SubState', 'MainPID', 'InvocationID', 'Result',
            'ExecMainCode', 'ExecMainStatus', 'ControlGroup', 'ExecMainExitTimestamp')
    text = subprocess.check_output(['systemctl', '--user', 'show', unit,
        *['--property='+key for key in keys]], text=True, timeout=5)
    result = dict(line.split('=', 1) for line in text.splitlines())
    result.update(unit=unit, invocation_id=result['InvocationID'],
        boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip())
    return result


def validate(observed, expected):
    if observed['InvocationID'] != expected['invocation_id']:
        raise ValueError('invocation disappeared/replaced: '+expected['unit'])
    if observed['ActiveState'] in ('inactive', 'failed') and observed['MainPID'] == '0':
        if not observed['ExecMainExitTimestamp']:
            raise ValueError('closed state without an actual process exit')
        return True  # Archive a failure too; this is NOT an acceptance verdict.
    if observed['MainPID'] != str(expected['owner_pid']):
        raise ValueError('unexpected process owner: '+expected['unit'])
    return False


def save(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.flush()
        import os
        os.fsync(stream.fileno())


def main():
    import dbus
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--expect', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--seconds', type=int, default=262800)
    args = ap.parse_args()
    assert __debug__ and 1 <= args.seconds <= 262800
    assert args.out.resolve().is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    raw = args.expect.read_bytes(); expected = json.loads(raw)
    assert isinstance(expected, list) and 1 <= len(expected) <= 16
    assert len({item['unit'] for item in expected}) == len(expected)
    for item in expected:
        assert re.fullmatch(r'ventium-[a-z0-9-]+\.service', item['unit'])
        assert re.fullmatch(r'[0-9a-f]{32}', item['invocation_id'])
        assert type(item['owner_pid']) is int and item['owner_pid'] > 0
    args.out.mkdir()
    bus = dbus.SessionBus(private=True)
    manager = dbus.Interface(bus.get_object('org.freedesktop.systemd1', '/org/freedesktop/systemd1'),
                             'org.freedesktop.systemd1.Manager')
    held = set(); archived = []; error = None; started = time.monotonic()
    try:
        admissions = []
        for item in expected:
            manager.RefUnit(item['unit']); held.add(item['unit'])
            observed = query(item['unit']); validate(observed, item)
            admissions.append(observed)
        save(args.out/'admitted.json', dict(expect_sha256=hashlib.sha256(raw).hexdigest(),
            observed=admissions, metadata_only=True, acceptance=False))
        print('Holding '+str(len(held))+' supervisor identities only', flush=True)
        while held:
            if time.monotonic()-started >= args.seconds:
                raise TimeoutError('metadata keeper time bound')
            for item in expected:
                if item['unit'] not in held:
                    continue
                observed = query(item['unit'])
                if validate(observed, item):
                    second = query(item['unit'])
                    assert second == observed
                    save(args.out/(item['unit']+'.json'), observed)
                    archived.append(item['unit'])
                    manager.UnrefUnit(item['unit']); held.remove(item['unit'])
                    print('Archived closure: '+item['unit'], flush=True)
            if held:
                time.sleep(1)
    except BaseException as exc:
        error = repr(exc)
    finally:
        for unit in held:
            manager.UnrefUnit(unit)
        bus.close()
        save(args.out/'closed.json', dict(archived=archived, error=error,
            all_archived=len(archived)==len(expected), acceptance=False))
    if error:
        raise RuntimeError(error)


if __name__ == '__main__':
    main()
