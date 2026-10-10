#!/usr/bin/env python3
"""Bounded cold-run closure and clock restoration, not timedemo acceptance."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import time
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
from ven_uv_fast_guard import require_running
from ven_quake_ipc import endpoint as ipc_endpoint, Accumulator
from ven_cold_owners import OwnedServices, OwnershipError

ap = argparse.ArgumentParser()
ap.add_argument('root', type=Path)
ap.add_argument('daemon_unit')
ap.add_argument('capture_unit')
a = ap.parse_args()
assert os.geteuid() == 0
root = a.root.resolve(strict=True)
assert str(root).startswith('/dev/shm/ventium-quake-abi5-run.')
image_sha=(root/'inputs/expected-image.sha256').read_text().strip()
assert len(image_sha)==64 and hashlib.sha256(Path('/lib/firmware/ventium_uvfast_posted16_40.bit.bin').read_bytes()).hexdigest()==image_sha
probe_path = root/'inputs/ven_board_probe.py'
subprocess.run(['sha256sum','--strict','--check',str(root/'inputs/expected.sha256')],
               check=True, stdout=subprocess.DEVNULL, timeout=60)
spec = importlib.util.spec_from_file_location('pinned_debug_probe', probe_path)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

def unit(name):
    text = subprocess.check_output(['systemctl', '--no-pager', 'show', name,
        '-p', 'Id', '-p', 'InvocationID', '-p', 'MainPID', '-p', 'Result',
        '-p', 'ExecMainCode', '-p', 'ExecMainStatus', '-p', 'ActiveState', '-p', 'SubState',
        '-p', 'TasksCurrent'],
        timeout=5, text=True)
    return dict(line.split('=', 1) for line in text.splitlines())

def save(name, value):
    # Publish only a complete receipt. start_once waits on pathname existence;
    # creating the final name before json.dump exposed a zero-byte startup file.
    target = root / name
    pending = root / (name + '.pending')
    with pending.open('x') as out:
        json.dump(value, out, indent=2)
        out.write('\n')
        out.flush()
        os.fsync(out.fileno())
    os.link(pending, target)  # Atomic publication, refusing an existing target.
    pending.unlink()

def command(name, args, timeout=15):
    with (root / name).open('xb') as out:
        rc = subprocess.run(args, stdout=out, stderr=subprocess.STDOUT,
                            timeout=timeout).returncode
    with (root / (name + '.exit.txt')).open('x') as out:
        out.write(str(rc) + '\n')
    return rc

daemon_initial = unit(a.daemon_unit)
capture_initial = unit(a.capture_unit)
for initial in (daemon_initial, capture_initial):
    assert initial['SubState'] == 'running' and int(initial['MainPID']) > 0
    assert len(initial['InvocationID']) == 32
rc = 1
capture_failed = False
owners = OwnedServices({a.capture_unit:capture_initial,a.daemon_unit:daemon_initial}, unit,
    lambda name: subprocess.run(['systemctl','stop',name],check=True,timeout=35),
    lambda name,sig: subprocess.run(['systemctl','kill','--kill-who=main','--signal='+sig,name],
                                   check=True,timeout=5))
fd = ctrl = guest = None
gameplay = Accumulator()
stop_signal = None

def request_stop(signum, frame):
    global stop_signal
    stop_signal = signum

signal.signal(signal.SIGTERM, request_stop)
signal.signal(signal.SIGINT, request_stop)

try:
    fd, ctrl, _ = probe.open_mmio(writable=True)
    probe.require_exec_debug(ctrl)
    guest = probe.map_region(fd,probe.DDR_BASE,0x1000000,writable=False)
    save('watch-start.json', {'daemon': daemon_initial, 'capture': capture_initial,
                             'clock_restoration_target': 'iopll-100m', 'acceptance': False})
    deadline = time.monotonic() + 3600
    with (root / 'live-status.jsonl').open('x') as log:
        while True:
            d, c = unit(a.daemon_unit), unit(a.capture_unit)
            assert d['InvocationID'] == daemon_initial['InvocationID']
            assert c['InvocationID'] == capture_initial['InvocationID']
            observation = None
            measured_interval = None
            state = probe.debug_state(ctrl)  # Non-ring read-only CSRs only.
            record={'monotonic_ns': time.monotonic_ns(), 'daemon': d,
                                  'capture': c, 'state': state,
                    'capture_status': f'{probe.u32(ctrl, probe.R_CAP_STATUS):08x}'}
            if (root/'release.txt.exit.txt').exists() and int(d['MainPID']) > 0:
                assert (root/'release.txt.exit.txt').read_text().strip() == '0'
                observation = ipc_endpoint(lambda off: probe.u32(ctrl, off),
                    lambda off, value: struct.pack_into('<I', ctrl, off, value),
                    lambda off: probe.u32(guest, off))
                measured_interval = gameplay.add(observation)
            record['ipc_observation'] = observation
            record['ipc_interval'] = measured_interval
            log.write(json.dumps(record)+'\n')
            log.flush()
            if (root/'release.txt.exit.txt').exists() and int(d['MainPID']) > 0:
                assert (root/'release.txt.exit.txt').read_text().strip()=='0'
                try:require_running(probe.execution_ctrl(ctrl),probe.u32(ctrl,probe.R_DBG_FRZINFO),
                                    capability=probe.u32(ctrl,probe.R_DBG_EXEC_CAP))
                except ValueError as error:
                    save('uv-fast-running-guard-failure.json',dict(error=str(error),state=state,acceptance=False))
                    break
            if int(d['MainPID']) == 0:
                rc = 0 if d['ExecMainCode'] == '1' and d['ExecMainStatus'] == '0' and not capture_failed else 1
                break
            if int(c['MainPID']) == 0 and c['ExecMainStatus'] != '0' and not capture_failed:
                capture_failed = True
                save('capture-failure-while-guest-continues.json', c)
            if state['freeze']['frozen']:
                break
            if stop_signal is not None:
                save('watch-signal.json',dict(signal=stop_signal,acceptance=False))
                rc = 1
                break
            if (root/'stop-request.json').exists():
                request=json.loads((root/'stop-request.json').read_text())
                assert request.get('reason') in ('observed-demo-end','operator-stop','capture-failure')
                save('operator-stop-observed.json',dict(request=request,acceptance=False))
                break
            if time.monotonic() >= deadline:
                save('watch-timeout.json',dict(seconds=3600,acceptance=False))
                break
            time.sleep(2)
    # Close the recorder on a complete-record boundary before changing the clock.
    owners.signal(a.capture_unit,'SIGUSR1')
    capture_deadline = time.monotonic() + 615
    while (int(owners.observe(a.capture_unit)['MainPID']) > 0 and
           time.monotonic() < capture_deadline and stop_signal is None):
        time.sleep(.5)
    c = owners.observe(a.capture_unit)
    save('capture-native-close.json', c)
    if not owners.quiescent(c) or c.get('ExecMainCode') != '1' or c.get('ExecMainStatus') != '0':
        rc = 1
    if int(owners.observe(a.daemon_unit)['MainPID']) > 0:
        save('daemon-forced-stop-request.json', {'observed_before_stop':owners.observe(a.daemon_unit),
                                              'natural_exit_observed':False,'acceptance':False})
        owners.stop(a.daemon_unit)
        rc = 1
    save('daemon-native-close.json', owners.observe(a.daemon_unit))
    # A timed-out recorder must also be reaped before HALT/RAM/debug operations.
    owners.close_all()
    # Safe architectural park, then a complete DDR copy; no RAM repair/STEP/BP.
    halted = command('final-halt.txt', ['python3', str(probe_path), 'halt', '--timeout', '2'])
    if halted == 0:
        command('final-state.json', ['python3', str(probe_path), 'dump-state', '--timeout', '2'])
        command('final-ring.txt', ['python3', str(probe_path),'dump-ring','--allow-live','--depth','128'])
    command('physical-ram.receipt.txt', ['python3', str(probe_path), 'dump-ram',
        '--start', '0', '--length', '0x1000000', '--ram-size', '0x1000000',
        '--output', str(root/'physical-ram.bin')], timeout=45)
finally:
    try:
        # Recheck immutable identities in the failure path too. On replacement,
        # close other owned workers but do not touch the new owner or hardware.
        try:
            closed_owners = owners.close_all()
        except OwnershipError as error:
            save('cleanup-refused.json',dict(error=str(error),cleanup_reset_clock_skipped=True,acceptance=False))
            raise
        save('owners-before-clock-restore.json', closed_owners)
        if ctrl is None:
            raise RuntimeError('no admitted MMIO mapping for clock/reset restoration')
        owners.require_closed()
        probe.require_exec_debug(ctrl)
        assert probe.u32(ctrl, probe.R_IDENT) == probe.IDENT_MAGIC
        struct.pack_into('<I', ctrl, 0x20, 1)  # Hold guest reset after evidence capture.
        assert probe.u32(ctrl, 0x20) == 1
        assert command('restore-40.txt', ['python3', str(probe_path), 'clock', 'iopll-100m']) == 0
        save('gameplay-observation.json', dict(gameplay.result(), image_sha256=image_sha))
        save('watch-closed.json', {'exit': rc, 'clock_restored': True,
                                'guest_held_reset': True, 'acceptance': False,
                                'scope': '40MHz UV fast native closure only; independent console and movie audit required',
                                'image_sha256':image_sha,'total_UV_gameplay_ipc':None})
    finally:
        if guest is not None: guest.close()
        if ctrl is not None: ctrl.close()
        if fd is not None: os.close(fd)
raise SystemExit(rc)
