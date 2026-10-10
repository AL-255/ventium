#!/usr/bin/env python3
"""Start one private cold diagnostic; never grades completion or modifies payloads."""
import json
import os
from pathlib import Path
import re
import subprocess
import time

import sys
from ven_cold_owners import OwnedServices
ROOT = Path(sys.argv[1]).resolve(strict=True)
assert os.geteuid() == 0 and ROOT.is_dir()
assert re.fullmatch(r'/dev/shm/ventium-quake-abi5-run\.[A-Za-z0-9]+',str(ROOT))
(ROOT/'launch.once').mkdir()
capture_unit = 'ventium-vcap-abi540-'+ROOT.name.rsplit('.',1)[1]
daemon_unit = None
watcher_owned = False
worker_owners = {}
watcher_unit = None

def unit(name):
    args = ['systemctl','show',name]
    for field in ('Id','InvocationID','MainPID','ActiveState','SubState','TasksCurrent'):
        args += ['-p',field]
    text = subprocess.check_output(args,text=True,timeout=5)
    return dict(line.split('=',1) for line in text.splitlines())

def remember(name, expected=None):
    observed = unit(name)
    if expected is not None:
        assert all(observed[key] == value for key,value in expected.items())
    worker_owners[name] = OwnedServices({name:observed},unit,
        lambda target: subprocess.run(['systemctl','stop',target],check=True,timeout=35),
        lambda target,sig: subprocess.run(['systemctl','kill','--kill-who=main','--signal='+sig,target],
                                        check=True,timeout=5))
    return observed

def command(name, argv, timeout=120, env=None):
    with (ROOT/name).open('xb') as out:
        rc = subprocess.run(argv, stdout=out, stderr=subprocess.STDOUT,
                            timeout=timeout, env=env).returncode
    marker = ROOT/(name+'.exit.txt')
    pending = ROOT/(name+'.exit.txt.pending')
    with pending.open('x') as out:
        out.write(str(rc)+'\n')
    os.link(pending, marker)
    pending.unlink()
    if rc:
        raise RuntimeError(f'{name}: exit {rc}; do not retry this leaf')

try:
    assert json.loads((ROOT/'held-clock.json').read_text())['result'] == 'PASS_HELD_RESET_40MHZ_ONLY'
    prepared = json.loads((ROOT/'prepare.json').read_text())
    assert prepared['action'] == 'prepare-cold-abi5' and prepared['guest_held_reset']
    assert not prepared['guest_released'] and prepared['after']['counters']['retirements'] == 0
    command('input-check.log', ['sha256sum','-c',str(ROOT/'inputs/expected.sha256')])
    assert os.statvfs('/dev/shm').f_bavail * os.statvfs('/dev/shm').f_frsize > 100000000
    pids = subprocess.check_output(['pgrep','-f','^/bin/cat -- '+re.escape(str(ROOT/'capture/pixels.fifo'))+'$'], text=True).split()
    assert len(pids) == 1
    command('capture-launch.log', ['python3',str(ROOT/'inputs/start_capture_service.py'),
        '--expected-sha-manifest',str(ROOT/'inputs/expected.sha256'),
        '--final-bit','/lib/firmware/ventium_uvfast_posted16_40.bit.bin',
        '--daemon','/tmp/ao486/ao486d.posted-safe-oct08',
        '--boot0','/tmp/ao486/boot0.rom','--boot1','/tmp/ao486/boot1.rom',
        '--input-vhd','/tmp/ao486/quake-cold-oct02.vhd',
        '--capture-dir',str(ROOT/'capture'),'--fifo',str(ROOT/'capture/pixels.fifo'),
        '--reader-pid',pids[0],'--unit',capture_unit])
    capture_initial = remember(capture_unit+'.service')
    env = dict(os.environ, VENTIUM_COLD_RUNDIR=str(ROOT), PYTHONDONTWRITEBYTECODE='1')
    command('cold-launch.log', ['bash',str(ROOT/'inputs/launch_cold_quake.sh'),
        str(ROOT/'inputs/expected.sha256'),capture_unit+'.service'], env=env)
    fields = dict(line.split('=',1) for line in (ROOT/'cold-launch.log').read_text().splitlines()
                  if line.startswith('LAUNCHED_'))
    daemon_unit = fields['LAUNCHED_UNIT']
    assert re.fullmatch(r'ventium-quake-cold-[A-Za-z0-9]+\.service',daemon_unit)
    daemon_initial = remember(daemon_unit,dict(InvocationID=fields['LAUNCHED_INVOCATION'],
                                               MainPID=fields['LAUNCHED_MAINPID']))
    native_root = Path(fields['LAUNCHED_RUNDIR'])
    assert native_root.parent == ROOT
    deadline = time.monotonic()+30
    while not (native_root/'daemon.stderr').exists() or 'x86_init done;' not in (native_root/'daemon.stderr').read_text():
        assert time.monotonic()<deadline
        time.sleep(.2)
    command('before-release-state.json', ['python3',str(ROOT/'inputs/ven_board_probe.py'),
                                         'dump-state','--timeout','2'], timeout=15)
    initial = json.loads((ROOT/'before-release-state.json').read_text())
    assert initial['architectural_state']['cs']=='f000'
    assert initial['architectural_state']['eip']=='0000fff0'
    assert not initial['debug_state']['freeze']['frozen']
    assert not initial['debug_state']['execution']['breakpoint_enabled']
    assert initial['debug_state']['execution']['halted']
    watcher_unit = 'ventium-quake-abi5-watch-'+ROOT.name.rsplit('.',1)[1]
    command('watch-launch.log', ['systemd-run','--unit='+watcher_unit,
        '--property=Type=exec','--property=PrivateTmp=no','--property=RemainAfterExit=yes',
        '--property=RuntimeMaxSec=4500','--property=MemoryMax=256M','--property=MemorySwapMax=0',
        '--property=TasksMax=32','--property=StandardOutput=file:'+str(ROOT/'watch.stdout'),
        '--property=StandardError=file:'+str(ROOT/'watch.stderr'),
        'python3',str(ROOT/'inputs/watch_cold.py'),str(ROOT),daemon_unit,capture_unit+'.service'])
    # Delegate restoration only after a positive live watcher/PID observation.
    remember(watcher_unit+'.service')
    activation_deadline=time.monotonic()+5
    while not (ROOT/'watch-start.json').exists():
        assert time.monotonic()<activation_deadline
        live=worker_owners[watcher_unit+'.service'].observe(watcher_unit+'.service')
        assert int(live['MainPID'])>0 and live['SubState']=='running'
        time.sleep(.05)
    watch_start=json.loads((ROOT/'watch-start.json').read_text())
    for label,initial in (('daemon',daemon_initial),('capture',capture_initial)):
        assert all(watch_start[label][key]==initial[key] for key in ('Id','InvocationID','MainPID'))
    watcher_owned=True
    command('release.txt', ['python3',str(ROOT/'inputs/ven_board_probe.py'),'run','--timeout','2'])
    with (ROOT/'started.json').open('x') as out:
        json.dump({'root':str(ROOT),'native_root':str(native_root),'daemon_unit':daemon_unit,
            'capture_unit':capture_unit+'.service','watcher_unit':watcher_unit+'.service',
            'measured_core_mhz':json.loads((ROOT/'held-clock.json').read_text())['measured_core_mhz'],
            'no_snapshot':True,'no_step':True,'no_breakpoint':True,
            'no_guest_payload_patch':True,'acceptance':False},out,indent=2)
    print((ROOT/'started.json').read_text())
finally:
    if not watcher_owned:
        # Stop an admitted watcher first so it cannot race this failure cleanup.
        # Unobserved/replaced services are never adopted or killed by name.
        names = list(worker_owners)
        if watcher_unit and watcher_unit+'.service' in names:
            names.remove(watcher_unit+'.service')
            names.insert(0,watcher_unit+'.service')
        errors = []
        for name in names:
            try:
                worker_owners[name].close_all()
            except Exception as error:
                errors.append(dict(unit=name,error=str(error)))
        # Initialization never changes the admitted 40 MHz source clock. On a
        # failed handoff, preserve hardware/evidence rather than unconditionally
        # changing its clock with incomplete native-worker ownership.
        with (ROOT/'failed-start-cleanup.json').open('x') as out:
            json.dump(dict(errors=errors,observed_units=names,hardware_writes_by_launcher_cleanup=False,
                           guest_state_requires_inspection=True,acceptance=False),out,indent=2)
