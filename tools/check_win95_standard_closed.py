#!/usr/bin/env python3
"""Host-only qualification of a CLOSED cold Win95 desktop run.

No guest, model, launcher or local verifier module is executed or imported.
An externally reviewed --expect SHA pins the identities and complete frozen
input map. A separately reviewed --visual-review SHA is mandatory human
authority: this program cannot recognize a desktop. That review must name
actual closed raw PPM hashes, not previews or a live screenshot.

Expectation schema 1: kind=WIN95_STANDARD_EXPECTATION, run_directory, unit,
invocation_id, boot_id, affinity, owner_pid, native_pid, model_sha256,
launcher_path, launcher_sha256, pristine_disk_path, pristine_disk_sha256,
helper_source_paths, helper_sha256, rom_source_paths, rom_sha256, pins,
receipt_before_sha256 and native_admission_sha256. Paths are absolute.
The two helper names are check_quake_timedemo/run_quake_standard; ROM names
are boot0.rom/boot1.rom. pins is the EXACT wrapper input_sha256_before map.

Visual schema 1: kind=WIN95_MANUAL_DESKTOP_REVIEW, authority=manual,
reviewer, reviewed_unix, run_directory, unit, invocation_id, model_sha256,
desktop=true, error_free=true, review_basis=closed_raw_frames, and raw_frames
[{path, sha256}]. JSON is not independent proof of a past wait or human review:
the caller owns the external SHA/identity authority. A PASS is Win95 only,
never the complete standard suite. CLOSED_UNQUALIFIED/exit0 alone is not PASS.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess


SHA = re.compile(r'[0-9a-f]{64}\Z')
SECONDS, CYCLES, DISK_SIZE = 259200, 9000000000, 2 * 1024**3
JSON_LIMIT, LOG_LIMIT, FRAME_LIMIT = 1024**2, 64 * 1024**2, 2 * 1024**2
ERROR = re.compile(
    rb'Invalid\s+VxD\s+dynamic\s+link\s+call|Windows\s+protection\s+error|'
    rb'\bA\s+fatal\s+exception\s*[0-9A-F]{2}\s+has\s+occurred\b|'
    rb'%Error\b|Assertion failed|SNAPSHOT-ERROR:|RETIRE-STOP-FAIL\b|'
    rb'HOST-STOP-ERROR|terminate called|Segmentation fault|AddressSanitizer:|'
    rb'runtime error:|CPU HUNG|FAULT-RING-ERROR|PC-SNAPSHOT-ERROR|'
    rb'>>> STATE LOADED from ', re.I)
PROGRESS_START = re.compile(rb'\[\s*\d+\] retires=')
PROGRESS = re.compile(rb'\[\s*(\d+)\] retires=(\d+) cs=[0-9a-f]{4}:eip=[0-9a-f]{8} '
                      rb'cr0=[0-9a-f]{8} cr3=[0-9a-f]{8} eflags=[0-9a-f]{8}\n', re.I)


def require(ok, message):
    if not ok:
        raise ValueError(message)


def integer(value, expected=None):
    return type(value) is int and (expected is None or value == expected)


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def pairs(items):
    value = {}
    for key, item in items:
        require(key not in value, 'duplicate JSON key')
        value[key] = item
    return value


def absolute(value):
    require(type(value) is str and Path(value).is_absolute() and
            str(Path(value)) == value, 'noncanonical absolute path')
    return Path(value)


class Files:
    """Held regular inodes; bounded reads, stable hashes, audit-wide recheck."""
    def __init__(self):
        self.observed = {}

    def read(self, path, *, limit=JSON_LIMIT, digest_only=False, size=None):
        path = Path(path)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and
                    before.st_size <= limit and (size is None or before.st_size == size),
                    'unsafe/oversized/wrong-size evidence file')
            digest, chunks, total = hashlib.sha256(), [], 0
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                total += len(chunk)
                require(total <= before.st_size, 'evidence grew during read')
                digest.update(chunk)
                if not digest_only:
                    chunks.append(chunk)
            after, named = os.fstat(fd), path.lstat()
            fields = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_nlink')
            identity = lambda item: tuple(getattr(item, key) for key in fields)
            require(total == before.st_size and identity(before) == identity(after) == identity(named),
                    'evidence changed/replaced during read')
            key, observation = str(path.absolute()), (identity(after), digest.hexdigest(), limit, size)
            require(key not in self.observed or self.observed[key] == observation, 'evidence changed during audit')
            self.observed[key] = observation
            return digest.hexdigest() if digest_only else b''.join(chunks)
        finally:
            os.close(fd)

    def json(self, path):
        def bad_constant(_value):
            raise ValueError('non-finite JSON number')
        return json.loads(self.read(path), object_pairs_hook=pairs, parse_constant=bad_constant)

    def digest_disk(self, path):
        return self.read(path, limit=DISK_SIZE, size=DISK_SIZE, digest_only=True)

    def finish(self):
        for path, (_, _, limit, size) in list(self.observed.items()):
            self.read(path, limit=limit, size=size, digest_only=True)


def query_supervisor(unit):
    keys = ('ActiveState', 'SubState', 'MainPID', 'InvocationID', 'Result',
            'ExecMainCode', 'ExecMainStatus', 'ControlGroup', 'ExecMainExitTimestamp')
    raw = subprocess.run(['/usr/bin/systemctl', '--user', 'show', unit,
                          *['--property=' + key for key in keys]],
                         stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=5).stdout.decode()
    value = pairs(line.split('=', 1) for line in raw.splitlines())
    value.update(unit=unit, invocation_id=value.get('InvocationID'),
                 boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip())
    return value


def processes_absent(expected):
    """Must run BEFORE opening any log/frame/disk, and again after the audit."""
    for pid in (expected['owner_pid'], expected['native_pid']):
        require(integer(pid) and pid > 0, 'invalid recorded process PID')
        try:
            os.stat(Path('/proc') / str(pid))
        except FileNotFoundError:
            continue
        raise ValueError('recorded process still exists, including zombies; do not grade live files')
    group = Path('/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice') / expected['unit']
    try:
        os.stat(group)
    except FileNotFoundError:
        return
    with (group / 'cgroup.procs').open('rb') as stream:
        procs = stream.read(65537)
    with (group / 'cgroup.events').open('rb') as stream:
        events = stream.read(65537)
    require(len(procs) <= 65536 and len(events) <= 65536 and not procs.strip() and
            pairs(line.split() for line in events.decode().splitlines()).get('populated') == '0',
            'owned cgroup is not recursively empty')


def supervisor_closed(value, expected):
    group = '/user.slice/user-1000.slice/user@1000.service/app.slice/' + expected['unit']
    require(value.get('unit') == expected['unit'] and value.get('invocation_id') == expected['invocation_id'] and
            value.get('InvocationID') == expected['invocation_id'] and value.get('boot_id') == expected['boot_id'] and
            value['boot_id'] == Path('/proc/sys/kernel/random/boot_id').read_text().strip(), 'wrong supervisor invocation/boot')
    require(tuple(value.get(key) for key in ('ActiveState', 'SubState', 'MainPID', 'Result',
                                          'ExecMainCode', 'ExecMainStatus')) ==
            ('inactive', 'dead', '0', 'success', '1', '0') and
            value.get('ControlGroup') in ('', group) and value.get('ExecMainExitTimestamp'),
            'supervisor has no actual successful inactive/dead owner wait')


def resource_receipt(value, expected):
    group = '/user.slice/user-1000.slice/user@1000.service/app.slice/' + expected['unit']
    worker, owner, limits = value['worker'], value['owner'], value['cgroup_files']
    require(value['unit'] == expected['unit'] and value['invocation_id'] == expected['invocation_id'] and
            value['boot_id'] == expected['boot_id'] and value['cgroup'] == '/sys/fs/cgroup' + group and
            value['no_oom'] is True and integer(value['file_size_limit'], 4 * 1024**3), 'wrong resource receipt identity')
    require(worker['pid'] == expected['owner_pid'] and integer(worker['pid']) and
            worker['affinity'] == expected['affinity'] and worker['cgroup'] == '0::' + group and
            integer(worker['starttime']) and worker['starttime'] > 0 and SHA.fullmatch(worker['exe_sha256']),
            'wrong recorded owner admission')
    require(owner == {'ActiveState': 'active', 'ControlGroup': group, 'InvocationID': expected['invocation_id'],
                      'KillMode': 'control-group', 'MainPID': str(expected['owner_pid']), 'RuntimeMaxUSec': '3d 1h'},
            'wrong direct supervisor resource owner')
    require(limits['memory.max'] == str(2 * 1024**3) and limits['memory.swap.max'] == '0' and
            limits['pids.max'] == '32' and limits['cgroup.procs'].split() == [str(expected['owner_pid'])],
            'wrong memory/swap/tasks/owner-only closure census')
    quota, period = limits['cpu.max'].split()
    require(quota.isdecimal() and period.isdecimal() and 0 < int(quota) <= int(period), 'unbounded CPU quota')
    for name in ('memory.events', 'memory.events.local'):
        events = pairs(line.split() for line in limits[name].splitlines())
        require(all(events.get(key) == '0' for key in ('oom', 'oom_kill', 'oom_group_kill')), 'OOM-tainted run')
    require(number(value['unix']), 'invalid receipt timestamp')


def closed_log(data, stop):
    require(data.endswith(b'\n') and not ERROR.search(data), 'terminal error/snapshot/truncated engine log')
    resets = list(re.finditer(rb'>>> ventium-soc: reset released; running up to (\d+) cycles\n', data))
    ends = list(re.finditer(rb'>>> done: cyc=(\d+) retires=(\d+) last cs=[0-9a-f]{4}:eip=[0-9a-f]{8}\n', data, re.I))
    require(len(resets) == data.count(b'>>> ventium-soc: reset released;') == 1 and
            int(resets[0][1]) == CYCLES and len(ends) == data.count(b'>>> done:') == 1 and
            resets[0].end() < ends[0].start(), 'missing/ambiguous normal cold header/footer')
    final_cycle, final_retire = map(int, ends[0].groups())
    require(0 < final_cycle < CYCLES and 0 < final_retire <= (1 << 64) - 1, 'cycle cap/invalid final counters')
    progress = list(PROGRESS.finditer(data))
    require({m.start() for m in PROGRESS_START.finditer(data)} == {m.start() for m in progress}, 'incomplete progress record')
    previous_cycle = previous_retire = 0
    for row in progress:
        cycle, retired = map(int, row.groups())
        require(resets[0].end() <= row.start() < row.end() <= ends[0].start() and
                cycle - previous_cycle >= 500000 and cycle <= final_cycle and
                previous_retire <= retired <= final_retire, 'progress order/counters regress')
        previous_cycle, previous_retire = cycle, retired
    require(final_cycle < 500000 or progress, 'missing progress')
    stops = list(re.finditer(rb'\[HOST-STOP\] request=' + re.escape(str(stop).encode()) +
                            rb' cycle=(\d+); host control only, not a benchmark pass\n', data))
    require(len(stops) == data.count(b'[HOST-STOP]') == 1 and int(stops[0][1]) == final_cycle and
            resets[0].end() < stops[0].start() < stops[0].end() <= ends[0].start(),
            'missing/ambiguous owned graceful closure; not desktop proof')
    return {'complete_progress_records': len(progress), 'final_cycle': final_cycle,
            'final_retires': final_retire, 'maximum_progress_interval_not_bounded': True}


def expected_command(run):
    return [str(run / 'ao486sim_ven_standard'), '--ide', str(run / 'guest.vhd'), '--rate', '45000000',
            '--rate-rtc', '45000000', '--rate-vga', '90000000', '--mem', '32', '--cycles', str(CYCLES),
            '--ddrlat', '2', '--mouse', '--vga-div', '4', '--vga-jit', '1', '--ven-perf-every', '100000000',
            '--vgatext-every', '25000000', '--fb-every', '100000000', '--fb-out', str(run / 'frame'),
            '--stop-request', str(run / 'stop.request')]


def check(run, expected, visual, *, supervisor=None):
    run, files = absolute(str(run)), Files()
    require(run.resolve(strict=True) == run and re.fullmatch(r'win95-cold-[A-Za-z0-9_.-]+', run.name), 'wrong owned run leaf')
    require(integer(expected['schema'], 1) and expected['kind'] == 'WIN95_STANDARD_EXPECTATION' and
            expected['run_directory'] == str(run) and
            re.fullmatch(r'ventium-standard-win95-[A-Za-z0-9_.-]+\.service', expected['unit']) and
            re.fullmatch(r'[0-9a-f]{32}', expected['invocation_id']) and
            len(expected['affinity']) == 1 and integer(expected['affinity'][0]) and expected['affinity'][0] >= 0 and
            expected['owner_pid'] != expected['native_pid'], 'wrong externally reviewed expectation')
    for name in ('model_sha256', 'launcher_sha256', 'pristine_disk_sha256',
                 'receipt_before_sha256', 'native_admission_sha256'):
        require(type(expected[name]) is str and SHA.fullmatch(expected[name]), 'invalid expected digest')
    closure = query_supervisor(expected['unit']) if supervisor is None else supervisor
    supervisor_closed(closure, expected)
    processes_absent(expected)  # No runtime files or disks have been opened yet.
    before_bytes, admission_bytes = files.read(run / 'receipt-before.json'), files.read(run / 'native-admission.json')
    require(hashlib.sha256(before_bytes).hexdigest() == expected['receipt_before_sha256'] and
            hashlib.sha256(admission_bytes).hexdigest() == expected['native_admission_sha256'], 'frozen admission receipt changed')
    before, admission = files.json(run / 'receipt-before.json'), files.json(run / 'native-admission.json')
    final, result = files.json(run / 'receipt-final.json'), files.json(run / 'result.json')
    resource_receipt(before, expected)
    resource_receipt(final, expected)
    require(final['worker'] == before['worker'] and before['unix'] <= final['unix'] < before['unix'] + SECONDS,
            'owner identity changed or wall cap reached')
    cmd, launcher = expected_command(run), absolute(expected['launcher_path'])
    require(launcher.parent == run.parent and launcher.name == 'run_win95_cold.py' and
            before['worker']['argv'] in (['/usr/bin/python3', str(launcher), str(run)],
                                       ['/usr/bin/python3', '-B', str(launcher), str(run)]), 'wrong observed launcher command')
    require(before['command'] == result['command'] == admission['argv'] == cmd and
            before['environment'] == {'PATH': '/usr/local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8', 'TMPDIR': str(run),
                                     'AO486_BIOS_DIR': str(run / 'rom'), 'AO486_RTC_EPOCH': '1789257600', 'FPGA_DDR': '2'},
            'nonstandard command/environment or guest hooks')
    for record in (before, result):
        require(record['cold_reset'] is True and record['snapshots'] is False and record['guest_modifications'] is False,
                'non-cold/modified guest')
    require(integer(before['wall_seconds_cap'], SECONDS) and
            before['source_provenance'] == 'exact executed helper archive bytes; launcher source observed before/after',
            'wrong frozen source/profile authority')
    require(integer(admission['pid'], expected['native_pid']) and integer(admission['ppid'], expected['owner_pid']) and
            admission['pgid'] == admission['sid'] == admission['pid'] and integer(admission['starttime']) and
            admission['starttime'] > 0 and admission['exe'] == cmd[0] and admission['exe_sha256'] == expected['model_sha256'] and
            admission['affinity'] == expected['affinity'] and admission['cgroup'] == before['worker']['cgroup'], 'wrong native admission')
    require(integer(result['schema'], 1) and result['kind'] == 'COLD_WIN95_CLOSURE' and result['status'] == 'CLOSED_UNQUALIFIED' and
            result['desktop_acceptance'] is False and result['suite_acceptance'] is False and
            integer(result['native_exit_code'], 0) and result['actual_child_wait'] is True and
            result['process_group_absent_after_wait'] is True and integer(result['native_pid'], expected['native_pid']) and
            result['native_admission'] == admission and result['terminal_error'] is None and
            result['stop_reason'] is None and result['errors'] == [] and result['host_stop_requested'] is True and
            result['candidate_sha256'] == expected['model_sha256'] and result['input_and_source_pins_unchanged'] is True,
            'native closure failed/incomplete or wrapper claimed desktop acceptance')
    require(result['final_resource_receipt_sha256'] == hashlib.sha256(files.read(run / 'receipt-final.json')).hexdigest(),
            'final resource receipt pin changed')
    pins = expected['pins']
    require(type(pins) is dict and pins and before['input_sha256_before'] == result['input_sha256_after'] == pins,
            'incomplete/changed input and source pin maps')
    require(set(expected['helper_sha256']) == set(expected['helper_source_paths']) ==
            {'check_quake_timedemo', 'run_quake_standard'} and
            set(expected['rom_sha256']) == set(expected['rom_source_paths']) == {'boot0.rom', 'boot1.rom'} and
            before['exact_loaded_helper_archives'] == expected['helper_sha256'], 'missing exact helper/ROM identities')
    roles = {str(launcher): expected['launcher_sha256'], str(run / 'observed-launcher.py'): expected['launcher_sha256'],
             str(run.parent / 'ao486sim_ven_standard'): expected['model_sha256'], cmd[0]: expected['model_sha256'],
             expected['pristine_disk_path']: expected['pristine_disk_sha256']}
    for name, digest in expected['helper_sha256'].items():
        roles.update({expected['helper_source_paths'][name]: digest, str(run / 'python' / (name + '.py')): digest})
    for name, digest in expected['rom_sha256'].items():
        roles.update({expected['rom_source_paths'][name]: digest, str(run / 'rom' / name): digest})
    require(all(pins.get(path) == digest for path, digest in roles.items()) and
            all(str(run.parent / name) in pins for name in ('Vsystem__verFiles.dat', 'compile-inputs.before.sha256', 'build-output.sha256')) and
            before['pristine_private_disk_sha256'] == expected['pristine_disk_sha256'], 'mandatory frozen pin roles missing')
    for path, digest in pins.items():
        require(type(digest) is str and SHA.fullmatch(digest), 'invalid source/input pin')
        path = absolute(path)
        observed = files.digest_disk(path) if str(path) == expected['pristine_disk_path'] else files.read(path, limit=LOG_LIMIT, digest_only=True)
        require(observed == digest, 'source/input/archive pin changed: ' + str(path))
    log = files.read(run / 'run.log', limit=LOG_LIMIT)
    capture = result['log_capture']
    log_identity = files.observed[str(run / 'run.log')][0]
    require(integer(capture['schema'], 1) and capture['actual_child_wait'] is True and integer(capture['sim_returncode'], 0) and
            capture['pipe_eof'] is True and capture['sticky_error'] is None and
            integer(capture['captured_bytes'], len(log)) and integer(capture['persisted_bytes'], len(log)) and
            capture['sha256'] == hashlib.sha256(log).hexdigest() and integer(capture['file_device'], log_identity[0]) and
            integer(capture['file_inode'], log_identity[1]) and integer(capture['byte_limit'], LOG_LIMIT), 'lossy/unclosed/rewritten pipe capture')
    stop = run / 'stop.request'
    require(files.read(stop) == b'', 'nonstandard owned empty stop request')
    counters = closed_log(log, stop)
    require(result['closed_engine_log'] == counters, 'closed footer/progress counters disagree')
    inventory, frames = result['closed_frame_inventory'], {}
    require(type(inventory) is list and inventory, 'no closed raw frame inventory')
    for frame in inventory:
        path = absolute(frame['path'])
        require(path.parent == run and re.fullmatch(r'frame_[0-9]{5}\.ppm', path.name) and str(path) not in frames,
                'invalid/duplicate closed raw frame')
        raw = files.read(path, limit=FRAME_LIMIT)
        require(integer(frame['size'], len(raw)) and frame['sha256'] == hashlib.sha256(raw).hexdigest(), 'closed raw frame changed')
        header = re.match(rb'P6\n([0-9]+) ([0-9]+)\n255\n', raw)
        require(header is not None and 0 < int(header[1]) <= 2048 and 0 < int(header[2]) <= 2048 and
                len(raw) == header.end() + 3 * int(header[1]) * int(header[2]), 'invalid/truncated raw RGB frame')
        frames[str(path)] = frame['sha256']
    require(set(frames) == {str(p) for p in run.glob('frame_*.ppm')}, 'closed raw inventory missing/added frame')
    publications = list(re.finditer(rb'\[FBCAP\] ([^\n]+?) mode=[^\n]+\n', log))
    reset_end = next(re.finditer(rb'>>> ventium-soc: reset released; running up to \d+ cycles\n', log)).end()
    require(len(publications) == len(frames) and {m[1].decode() for m in publications} == set(frames) and
            all(reset_end <= m.start() < m.end() <= log.index(b'>>> done:') for m in publications),
            'closed raw inventory lacks unique in-run native publications')
    require(integer(visual['schema'], 1) and visual['kind'] == 'WIN95_MANUAL_DESKTOP_REVIEW' and visual['authority'] == 'manual' and
            type(visual['reviewer']) is str and visual['reviewer'].strip() and visual['review_basis'] == 'closed_raw_frames' and
            visual['desktop'] is True and visual['error_free'] is True and number(visual['reviewed_unix']) and
            visual['reviewed_unix'] >= final['unix'] and visual['run_directory'] == str(run) and
            visual['unit'] == expected['unit'] and visual['invocation_id'] == expected['invocation_id'] and
            visual['model_sha256'] == expected['model_sha256'] and type(visual['raw_frames']) is list and visual['raw_frames'],
            'missing/early/unbound manual desktop authority')
    witnesses = {}
    for frame in visual['raw_frames']:
        require(frame['path'] not in witnesses and frames.get(frame['path']) == frame['sha256'], 'manual desktop witness not pinned closed raw frame')
        witnesses[frame['path']] = frame['sha256']
    disk_digest = files.digest_disk(run / 'guest.vhd')  # Only after authoritative closure and PID/cgroup absence.
    require(disk_digest == result['closed_private_disk_sha256'], 'closed private disk pin changed')
    files.finish()
    processes_absent(expected)
    supervisor_closed(query_supervisor(expected['unit']) if supervisor is None else supervisor, expected)
    return {'schema': 1, 'status': 'PASS', 'scope': 'Win95 cold boot to desktop only', 'suite_acceptance': False,
            'unit': expected['unit'], 'invocation_id': expected['invocation_id'], 'candidate_sha256': expected['model_sha256'],
            'closed_engine_log': counters, 'manual_desktop_frames': witnesses, 'closed_private_disk_sha256': disk_digest,
            'limitations': ['Desktop recognition is externally pinned manual authority, not automated recognition.',
                            'Exact loaded helper bytes; launcher source observed before/after, not loaded-memory ancestry.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--expect', required=True, type=Path)
    parser.add_argument('--expect-sha256', required=True)
    parser.add_argument('--visual-review', required=True, type=Path)
    parser.add_argument('--visual-review-sha256', required=True)
    parser.add_argument('--supervisor-closure', type=Path)
    parser.add_argument('--supervisor-sha256')
    args = parser.parse_args()
    try:
        files = Files()
        for path, digest in ((args.expect, args.expect_sha256), (args.visual_review, args.visual_review_sha256)):
            require(SHA.fullmatch(digest or '') and hashlib.sha256(files.read(path)).hexdigest() == digest,
                    'external expectation/manual-review digest missing or changed')
        supervisor = None
        if args.supervisor_closure is not None:
            require(SHA.fullmatch(args.supervisor_sha256 or '') and
                    hashlib.sha256(files.read(args.supervisor_closure)).hexdigest() == args.supervisor_sha256,
                    'external supervisor closure digest missing or changed')
            supervisor = files.json(args.supervisor_closure)
        else:
            require(args.supervisor_sha256 is None, 'supervisor digest without receipt')
        result = check(args.run.absolute(), files.json(args.expect), files.json(args.visual_review), supervisor=supervisor)
        files.finish()
    except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.SubprocessError) as exc:
        parser.exit(2, 'WIN95-STANDARD-CLOSED-FAIL: ' + str(exc) + '\n')
    result.update(expectation_sha256=args.expect_sha256, manual_visual_review_sha256=args.visual_review_sha256,
                  supervisor_receipt_sha256=args.supervisor_sha256)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
