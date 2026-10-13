"""Freeze independently checked live admission identities, never desktop PASS.

Reads immutable input/host records and /proc only; does not read the live guest
disk or frames, stop the guest, execute private helpers, or invent visual review.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

import prepare_fp_repair_cold as config

REPO = Path(__file__).resolve().parents[1]
UNIT = 'ventium-fp-repair-win95-oct13.service'
INVOCATION = '0cb50f29741b40fc91f3d6618f37be82'
DISK_SHA = '37f5db14225f753aa357e321606e75273726fe330a2b7bcd954a61f9337b1a56'
HELPERS = {'check_quake_timedemo': '427d9e7471eb4d6a65361fc468646307c66df4fe70fe8001e51977307bb85ad7',
           'run_quake_standard': 'bf715d90ec99b892e1c8ce5f7ac216821867ede598b278605769998cd27928c0'}
ROM_SHAS = {'boot0.rom': 'dca915c5483793a710ee118c5232aad01ef3191bea7d50c2befb1a47d2dd26a3',
            'boot1.rom': 'fb0d673a4cc3a96c388b4404db262db70bdde0746ee1ef9284923a5661e08296'}


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    root = ap.parse_args().root.resolve(strict=True)
    assert __debug__ and root == config.SCRATCH / 'ventium-fp-repair-transfer.a8nzrjHu'
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == config.SCRATCH
    soc = root / 'soc-r1'
    run = soc / 'win95-cold-fp-repair-oct13.1'
    expectation_path = root / 'win95-expectation.json'
    audit_path = root / 'win95-admission-audit.json'
    assert not expectation_path.exists() and not audit_path.exists()
    prepared = json.loads((root / 'win95-prepared.json').read_text())
    launcher = soc / 'run_win95_full_cold.py'
    invocation_path = Path('/home/yukidama/external/tmp') / root.name / 'soc-r1/run_win95_full_cold.py'
    assert not invocation_path.is_symlink() and invocation_path.resolve(strict=True) == launcher
    assert prepared['model'] == config.MODEL and prepared['manifest'] == config.MANIFEST
    assert prepared['launcher'] == str(launcher) and sha(launcher) == prepared['launcher_sha256']
    assert all(sha(p) == h for p, h in prepared['inputs'].items())
    build = json.loads((soc / 'build-started.json').read_text())
    assert all(sha(p) == h for p, h in build['pins'].items())
    before = json.loads((run / 'receipt-before.json').read_text())
    native = json.loads((run / 'native-admission.json').read_text())
    assert before['unit'] == UNIT and before['invocation_id'] == INVOCATION
    assert before['cold_reset'] and not before['snapshots'] and not before['guest_modifications']
    assert all(sha(p) == h for p, h in before['input_sha256_before'].items())
    assert before['worker']['argv'] == ['/usr/bin/python3', '-B', str(invocation_path), str(run)]
    assert before['worker']['affinity'] == native['affinity'] == [10]
    assert native['argv'] == before['command'] and native['ppid'] == before['worker']['pid']
    assert native['exe'] == str(run / 'ao486sim_board_posted')
    assert native['exe_sha256'] == sha(native['exe']) == config.MODEL
    assert native['pgid'] == native['sid'] == native['pid']
    props = subprocess.check_output(['systemctl', '--user', 'show', UNIT,
        '-p', 'InvocationID', '-p', 'ActiveState', '-p', 'SubState', '-p', 'MainPID'], text=True, timeout=5)
    owner = dict(line.split('=', 1) for line in props.splitlines())
    assert owner == dict(InvocationID=INVOCATION, ActiveState='active', SubState='running',
                         MainPID=str(native['ppid']))
    for record in (before['worker'], native):
        proc = Path('/proc') / str(record['pid'])
        assert proc.joinpath('exe').resolve(strict=True) == Path(record['exe'])
        assert proc.joinpath('cmdline').read_bytes().rstrip(b'\0').split(b'\0') == [a.encode() for a in record['argv']]
        assert proc.joinpath('cgroup').read_text().strip() == record['cgroup']
        assert int(proc.joinpath('stat').read_text().rsplit(')', 1)[1].split()[19]) == record['starttime']
        assert sorted(os.sched_getaffinity(record['pid'])) == [10]
    group = Path('/sys/fs/cgroup') / native['cgroup'].split('::', 1)[1].lstrip('/')
    assert group.name == UNIT
    actual_limits = {name: (group / name).read_text().strip() for name in
                     ('memory.max', 'memory.swap.max', 'pids.max', 'cpu.max', 'memory.events')}
    assert actual_limits['memory.max'] == str(2*1024**3)
    assert actual_limits['memory.swap.max'] == '0' and actual_limits['pids.max'] == '160'
    assert actual_limits['cpu.max'] == '100000 100000'
    events = dict(line.split() for line in actual_limits['memory.events'].splitlines())
    assert all(events[k] == '0' for k in ('oom', 'oom_kill', 'oom_group_kill'))
    definitions = set((soc / 'defines.txt').read_text().splitlines())
    command = next(line for line in (soc / 'obj1-speed-q16-parentpolicy/Vsystem__verFiles.dat').read_text().splitlines()
                   if line.startswith('C '))
    assert definitions | {'VEN_BOARD_POSTED_PROFILE', 'VEN_BOARD_WRITE_SLOTS'} == set(
        re.findall(r'(?:\+define\+|-D)(VEN_[A-Z0-9_]+)', command))
    assert {'VEN_FE_PIPE', 'VEN_SYS_FASTPATH', 'VEN_SYS_FASTPATH_RELOC',
            'VEN_SYS_FASTLOAD_FLAT', 'VEN_SYS_FASTLOAD_BOUNDED', 'VEN_SYS_FASTSTORE_FLAT'} <= definitions
    shim = (soc / 'source/ao486-sim/ven/ven_ao486_shim.sv').read_text()
    assert re.search(r'\.cycle_mode\s*\(1\x27b1\)', shim)
    assert not any(any(flag in arg for flag in ('snapshot', 'replay', 'step', 'break')) for arg in native['argv'])
    disk = REPO / 'ao486-sim/obj_dir_ven_rfcomplete_oct01.5mZtCG/qemu-vga-fixture-4VSF7/win95-standard-vga.raw'
    roms = REPO / 'ao486-sim/obj_dir_ven_axivgalanes_oct02.uVGIvV/quake-cold-axivgalanes-oct02.1/run/rom'
    assert sha(disk) == DISK_SHA and before['pristine_private_disk_sha256'] == DISK_SHA
    assert before['exact_loaded_helper_archives'] == HELPERS
    assert all(sha(REPO / 'tools' / (n + '.py')) == h for n, h in HELPERS.items())
    assert all(sha(roms / n) == h for n, h in ROM_SHAS.items())
    expected = dict(schema=5, kind='WIN95_STANDARD_EXPECTATION', profile='board-posted16-40mhz-parentpolicy160',
        run_directory=str(run), unit=UNIT, invocation_id=INVOCATION,
        boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(), affinity=[10],
        owner_pid=native['ppid'], native_pid=native['pid'], model_sha256=config.MODEL,
        launcher_path=str(launcher), launcher_sha256=sha(launcher),
        launcher_invocation_path=str(invocation_path),
        pristine_disk_path=str(disk), pristine_disk_sha256=DISK_SHA,
        helper_source_paths={n: str(REPO / 'tools' / (n + '.py')) for n in HELPERS}, helper_sha256=HELPERS,
        rom_source_paths={n: str(roms / n) for n in ROM_SHAS}, rom_sha256=ROM_SHAS,
        pins=before['input_sha256_before'], receipt_before_sha256=sha(run / 'receipt-before.json'),
        native_admission_sha256=sha(run / 'native-admission.json'))
    assert expected['boot_id'] == before['boot_id']
    with expectation_path.open('x') as f:
        json.dump(expected, f, indent=2)
    with audit_path.open('x') as f:
        json.dump(dict(live_admission_verified=True, owner=owner, actual_limits=actual_limits,
            source_pins_checked=len(build['pins']), runtime_pins_checked=len(expected['pins']),
            expectation_sha256=sha(expectation_path), checker_sha256=sha(REPO / 'tools/check_win95_standard_closed.py'),
            script_sha256=sha(__file__), unix=time.time(), model=config.MODEL,
            desktop_acceptance=False, ui_acceptance=False, standard_suite=False, gameplay_ipc=None,
            explanation='Live admission only. No live guest disk/frame read or visual acceptance generated.'), f, indent=2)
    print('WIN95 ADMISSION VERIFIED; expectation SHA256=' + sha(expectation_path), flush=True)


if __name__ == '__main__':
    main()
