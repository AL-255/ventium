#!/usr/bin/env python3
"""Stdlib HOST-ONLY Win95 checker contracts; never launch a guest/model.

All files are synthetic under tempfile's TMPDIR or system /tmp selection,
never a home-directory work folder. The two 2-GiB disk reads
are mocked with tiny fixture bytes so the negative matrix is quick; the real
disk reader's wrong-size refusal is tested separately. These are checker
contracts, not a Win95 boot or a manual review of genuine desktop pixels.
"""
import copy
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import check_win95_standard_closed as gate


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class ClosedWin95Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='obj_dir_win95closed_host_')
        self.build = Path(self.temp.name)
        self.run = self.build / 'win95-cold-host.fixture'
        self.run.mkdir()
        self.unit, self.inv = 'ventium-standard-win95-hostcontract.service', 'e' * 32
        self.owner, self.native = 2000000101, 2000000102
        self.boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        self.group = '/user.slice/user-1000.slice/user@1000.service/app.slice/' + self.unit
        pins = {}

        def pinned(path, body):
            path = Path(path)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(body)
            pins[str(path)] = sha(path)
            return path

        self.launcher = pinned(self.build / 'run_win95_cold.py', b'# synthetic frozen launcher; never executed\n')
        pinned(self.run / 'observed-launcher.py', self.launcher.read_bytes())
        self.model = pinned(self.build / 'ao486sim_ven_standard', b'synthetic native, not executable\n')
        pinned(self.run / 'ao486sim_ven_standard', self.model.read_bytes())
        for name in ('Vsystem__verFiles.dat', 'compile-inputs.before.sha256', 'build-output.sha256'):
            pinned(self.build / name, ('synthetic pinned ' + name + '\n').encode())
        self.pristine = pinned(self.build / 'source-pristine.vhd', b'mocked pristine disk bytes\n')
        (self.run / 'guest.vhd').write_bytes(b'mocked closed disk bytes\n')
        helpers, helper_paths, roms, rom_paths = {}, {}, {}, {}
        for name in ('check_quake_timedemo', 'run_quake_standard'):
            source = pinned(self.build / 'sources' / (name + '.py'), ('# mock archive ' + name + '\n').encode())
            archive = pinned(self.run / 'python' / source.name, source.read_bytes())
            helpers[name], helper_paths[name] = pins[str(archive)], str(source)
        for name in ('boot0.rom', 'boot1.rom'):
            source = pinned(self.build / 'sources' / name, ('mock ROM ' + name).encode())
            archive = pinned(self.run / 'rom' / name, source.read_bytes())
            roms[name], rom_paths[name] = pins[str(archive)], str(source)
        self.expect = {'schema': 1, 'kind': 'WIN95_STANDARD_EXPECTATION', 'run_directory': str(self.run),
                       'unit': self.unit, 'invocation_id': self.inv, 'boot_id': self.boot, 'affinity': [14],
                       'owner_pid': self.owner, 'native_pid': self.native, 'model_sha256': sha(self.model),
                       'launcher_path': str(self.launcher), 'launcher_sha256': sha(self.launcher),
                       'pristine_disk_path': str(self.pristine), 'pristine_disk_sha256': sha(self.pristine),
                       'helper_source_paths': helper_paths, 'helper_sha256': helpers,
                       'rom_source_paths': rom_paths, 'rom_sha256': roms, 'pins': pins}
        worker = {'pid': self.owner, 'ppid': 100, 'pgid': self.owner, 'sid': self.owner, 'starttime': 10,
                  'exe': '/usr/bin/python3.14', 'exe_sha256': 'a' * 64, 'affinity': [14], 'cgroup': '0::' + self.group,
                  'argv': ['/usr/bin/python3', str(self.launcher), str(self.run)]}
        limits = {'memory.max': str(2 * 1024**3), 'memory.swap.max': '0', 'pids.max': '32',
                  'cpu.max': '100000 100000', 'cgroup.procs': str(self.owner),
                  'memory.events': 'max 0\noom 0\noom_kill 0\noom_group_kill 0',
                  'memory.events.local': 'max 0\noom 0\noom_kill 0\noom_group_kill 0'}
        self.before = {'unit': self.unit, 'invocation_id': self.inv, 'boot_id': self.boot, 'unix': 100,
                       'cgroup': '/sys/fs/cgroup' + self.group, 'cgroup_files': limits, 'file_size_limit': 4 * 1024**3,
                       'no_oom': True, 'worker': worker,
                       'owner': {'ActiveState': 'active', 'ControlGroup': self.group, 'InvocationID': self.inv,
                                 'KillMode': 'control-group', 'MainPID': str(self.owner), 'RuntimeMaxUSec': '3d 1h'},
                       'command': gate.expected_command(self.run),
                       'environment': {'PATH': '/usr/local/bin:/usr/bin:/bin', 'LANG': 'C.UTF-8', 'TMPDIR': str(self.run),
                                       'AO486_BIOS_DIR': str(self.run / 'rom'), 'AO486_RTC_EPOCH': '1789257600', 'FPGA_DDR': '2'},
                       'cold_reset': True, 'snapshots': False, 'guest_modifications': False, 'wall_seconds_cap': gate.SECONDS,
                       'exact_loaded_helper_archives': helpers, 'input_sha256_before': pins,
                       'pristine_private_disk_sha256': sha(self.pristine),
                       'source_provenance': 'exact executed helper archive bytes; launcher source observed before/after'}
        self.admission = {'pid': self.native, 'ppid': self.owner, 'pgid': self.native, 'sid': self.native, 'starttime': 20,
                          'exe': str(self.run / 'ao486sim_ven_standard'), 'exe_sha256': sha(self.model), 'affinity': [14],
                          'cgroup': '0::' + self.group, 'argv': gate.expected_command(self.run)}
        self.final = copy.deepcopy(self.before)
        self.final['unix'] = 200
        self.result = {'schema': 1, 'kind': 'COLD_WIN95_CLOSURE', 'status': 'CLOSED_UNQUALIFIED',
                       'desktop_acceptance': False, 'suite_acceptance': False, 'native_pid': self.native,
                       'native_exit_code': 0, 'actual_child_wait': True, 'process_group_absent_after_wait': True,
                       'native_admission': self.admission, 'terminal_error': None, 'stop_reason': None, 'errors': [],
                       'command': gate.expected_command(self.run), 'host_stop_requested': True,
                       'candidate_sha256': sha(self.model), 'cold_reset': True, 'snapshots': False, 'guest_modifications': False,
                       'input_sha256_after': pins, 'input_and_source_pins_unchanged': True,
                       'closed_private_disk_sha256': sha(self.run / 'guest.vhd')}
        self.frame = self.run / 'frame_00000.ppm'
        self.frame.write_bytes(b'P6\n640 480\n255\n' + b'\0' * (640 * 480 * 3))
        self.result['closed_frame_inventory'] = [{'path': str(self.frame), 'sha256': sha(self.frame), 'size': self.frame.stat().st_size}]
        self.visual = {'schema': 1, 'kind': 'WIN95_MANUAL_DESKTOP_REVIEW', 'authority': 'manual',
                       'reviewer': 'synthetic host contract fixture, NOT an actual desktop review', 'reviewed_unix': 300,
                       'run_directory': str(self.run), 'unit': self.unit, 'invocation_id': self.inv,
                       'model_sha256': sha(self.model), 'review_basis': 'closed_raw_frames', 'desktop': True,
                       'error_free': True, 'raw_frames': [{'path': str(self.frame), 'sha256': sha(self.frame)}]}
        self.supervisor = {'unit': self.unit, 'invocation_id': self.inv, 'InvocationID': self.inv, 'boot_id': self.boot,
                           'ActiveState': 'inactive', 'SubState': 'dead', 'MainPID': '0', 'Result': 'success',
                           'ExecMainCode': '1', 'ExecMainStatus': '0', 'ControlGroup': self.group,
                           'ExecMainExitTimestamp': 'synthetic actual-wait fixture'}
        (self.run / 'stop.request').write_bytes(b'')
        self.log = (f'>>> ventium-soc: reset released; running up to {gate.CYCLES} cycles\n'
                    '[    500000] retires=40000 cs=0008:eip=00010000 cr0=00000011 cr3=00000000 eflags=00000002\n'
                    f'[FBCAP] {self.frame} mode=12h-16planar chain4=0 pel2=0 start=0 nz=0\n'
                    '[   1000000] retires=100000 cs=0008:eip=00010001 cr0=00000011 cr3=00000000 eflags=00000002\n'
                    f'[HOST-STOP] request={self.run / "stop.request"} cycle=1000000; host control only, not a benchmark pass\n'
                    '>>> done: cyc=1000000 retires=100000 last cs=0008:eip=00010001\n').encode()
        self.persist()

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def write(path, value):
        Path(path).write_text(json.dumps(value, sort_keys=True) + '\n')

    def persist(self):
        self.write(self.run / 'receipt-before.json', self.before)
        self.write(self.run / 'native-admission.json', self.admission)
        self.write(self.run / 'receipt-final.json', self.final)
        self.expect['receipt_before_sha256'] = sha(self.run / 'receipt-before.json')
        self.expect['native_admission_sha256'] = sha(self.run / 'native-admission.json')
        self.result['final_resource_receipt_sha256'] = sha(self.run / 'receipt-final.json')
        (self.run / 'run.log').write_bytes(self.log)
        st = (self.run / 'run.log').stat()
        self.result['log_capture'] = {'schema': 1, 'actual_child_wait': True, 'sim_returncode': 0, 'pipe_eof': True,
                                      'captured_bytes': len(self.log), 'persisted_bytes': len(self.log),
                                      'sha256': sha(self.run / 'run.log'), 'file_device': st.st_dev, 'file_inode': st.st_ino,
                                      'byte_limit': gate.LOG_LIMIT, 'sticky_error': None}
        self.result['closed_engine_log'] = {'complete_progress_records': 2, 'final_cycle': 1000000,
                                            'final_retires': 100000, 'maximum_progress_interval_not_bounded': True}
        self.write(self.run / 'result.json', self.result)

    def qualify(self):
        with patch.object(gate.Files, 'digest_disk', lambda _files, path: sha(path)):
            return gate.check(self.run, self.expect, self.visual, supervisor=self.supervisor)

    def reject(self):
        with self.assertRaises((ValueError, OSError, KeyError, TypeError)):
            self.qualify()

    def test_complete_closed_fixture_is_win95_only(self):
        value = self.qualify()
        self.assertEqual(value['status'], 'PASS')
        self.assertFalse(value['suite_acceptance'])
        self.assertIn('manual authority', value['limitations'][0])

    def test_no_bytecode_old_observed_launcher_is_supported(self):
        self.before['worker']['argv'].insert(1, '-B')
        self.final['worker'] = copy.deepcopy(self.before['worker'])
        self.persist()
        self.assertEqual(self.qualify()['status'], 'PASS')

    def rename_launcher(self, name):
        old, renamed = self.launcher, self.build / name
        old.rename(renamed)
        pins = self.expect['pins']
        pins[str(renamed)] = pins.pop(str(old))
        self.launcher = renamed
        self.expect['launcher_path'] = str(renamed)
        for record in (self.before, self.final):
            record['worker']['argv'] = ['/usr/bin/python3', str(renamed), str(self.run)]
        self.persist()

    def test_exact_vga_variant_with_separately_pinned_configured_source(self):
        self.rename_launcher('run_win95_vga_cold.py')
        old, configured = self.pristine, self.build / 'win95-standard-vga.raw'
        old.rename(configured)
        pins = self.expect['pins']
        pins[str(configured)] = pins.pop(str(old))
        self.pristine = configured
        self.expect['pristine_disk_path'] = str(configured)
        provenance = self.build / 'fixture-closed.json'
        provenance.write_bytes(b'{"kind":"synthetic native-installed VGA preparation; not guest acceptance"}\n')
        pins[str(provenance)] = sha(provenance)
        self.persist()
        value = self.qualify()
        self.assertEqual(value['status'], 'PASS')
        self.assertFalse(value['suite_acceptance'])

        for path in (configured, provenance):
            with self.subTest(mutated_pin=path.name):
                original = path.read_bytes()
                path.write_bytes(original + b'changed after the pinned receipt\n')
                self.reject()
                path.write_bytes(original)
        self.assertEqual(self.qualify()['status'], 'PASS')

    def test_unknown_launcher_even_with_consistent_external_pins_is_rejected(self):
        self.rename_launcher('run_win95_unreviewed.py')
        self.reject()

    def test_vga_variant_does_not_waive_launcher_sha_or_source_pin(self):
        self.rename_launcher('run_win95_vga_cold.py')
        good_sha = self.expect['launcher_sha256']
        self.expect['launcher_sha256'] = '0' * 64
        self.reject()
        self.expect['launcher_sha256'] = good_sha
        self.launcher.write_bytes(b'# mutated after the pinned before receipt\n')
        self.reject()

    def test_unknown_owner_options_are_not_allowed(self):
        self.before['worker']['argv'].insert(1, '-c')
        self.final['worker'] = copy.deepcopy(self.before['worker'])
        self.persist()
        self.reject()

    def test_supervisor_negative_matrix_precedes_runtime_reads(self):
        fields = [('ActiveState', 'active'), ('SubState', 'exited'), ('MainPID', '1'), ('Result', 'oom-kill'),
                  ('ExecMainCode', '0'), ('ExecMainStatus', '1'), ('InvocationID', '0' * 32),
                  ('invocation_id', '0' * 32), ('ControlGroup', '/wrong'), ('boot_id', 'wrong'), ('ExecMainExitTimestamp', '')]
        original = self.supervisor.copy()
        for key, bad in fields:
            with self.subTest(key=key), patch.object(gate.Files, 'digest_disk', side_effect=AssertionError('disk opened before closure')):
                self.supervisor = dict(original, **{key: bad})
                with self.assertRaises(ValueError):
                    gate.check(self.run, self.expect, self.visual, supervisor=self.supervisor)
        self.supervisor = original

    def test_present_owner_native_or_recursive_group_fails(self):
        with patch.object(gate, 'processes_absent', side_effect=ValueError('owned PID/group still present')):
            self.reject()
        expected = dict(self.expect, owner_pid=__import__('os').getpid())
        with self.assertRaises(ValueError):
            gate.processes_absent(expected)

    def test_native_actual_wait_and_negative_results(self):
        original = copy.deepcopy(self.result)
        for key, bad in [('native_exit_code', 2), ('native_exit_code', False), ('actual_child_wait', False),
                         ('process_group_absent_after_wait', False), ('terminal_error', 'fatal 0D'), ('errors', ['truncated']),
                         ('stop_reason', 'wall-time bound'), ('host_stop_requested', False), ('status', 'PASS'),
                         ('desktop_acceptance', True), ('suite_acceptance', True), ('native_pid', self.native + 1)]:
            with self.subTest(key=key, bad=bad):
                self.result = dict(copy.deepcopy(original), **{key: bad})
                self.write(self.run / 'result.json', self.result)
                self.reject()
        self.result = original

    def test_lossy_capture_negative_matrix(self):
        original = copy.deepcopy(self.result)
        for key, bad in [('pipe_eof', False), ('sticky_error', 'short write'), ('captured_bytes', len(self.log) + 1),
                         ('persisted_bytes', len(self.log) - 1), ('sha256', '0' * 64), ('file_inode', 0),
                         ('file_device', 0), ('actual_child_wait', False), ('sim_returncode', 2), ('byte_limit', 0)]:
            with self.subTest(key=key):
                self.result = copy.deepcopy(original)
                self.result['log_capture'][key] = bad
                self.write(self.run / 'result.json', self.result)
                self.reject()
        self.result = original

    def test_logs_truncated_capped_regressed_or_snapshot_are_rejected(self):
        original = self.log
        bad_logs = [original[:-1], original.replace(b'>>> done:', b'>>> missing:'),
                    original.replace(b'cyc=1000000', b'cyc=9000000000'), original + b'>>> STATE LOADED from fake\n',
                    original.replace(b'[   1000000] retires=100000', b'[   1000000] retires=1'),
                    original.replace(b'cr0=00000011 cr3=00000000 eflags=00000002\n', b'cr0=TRUNCATED\n', 1),
                    original.replace(b'[FBCAP]', b'[MISSING-FBCAP]'),
                    original.replace(b'[HOST-STOP]', b'[MISSING-STOP]'), original + b'A fatal exception0D has occurred\n',
                    original + b'a FATAL exception 0d has\noccurred\n', original + b'Invalid VxD dynamic link call\n']
        for bad in bad_logs:
            with self.subTest(log=bad[-120:]):
                self.log = bad
                self.persist()  # Even internally consistent forged byte receipts cannot waive grammar/errors.
                self.reject()
        self.log = original

    def test_manual_desktop_negative_matrix(self):
        original = copy.deepcopy(self.visual)
        for key, bad in [('authority', 'automatic'), ('desktop', False), ('error_free', False), ('reviewer', ''),
                         ('review_basis', 'live_screenshot'), ('reviewed_unix', 199), ('invocation_id', '0' * 32),
                         ('model_sha256', '0' * 64), ('raw_frames', []), ('schema', True)]:
            with self.subTest(key=key):
                self.visual = dict(copy.deepcopy(original), **{key: bad})
                self.reject()
        self.visual = copy.deepcopy(original)
        self.visual['raw_frames'][0]['sha256'] = '0' * 64
        self.reject()
        self.visual = copy.deepcopy(original)
        self.visual['raw_frames'][0]['path'] = str(self.frame.with_suffix('.png'))
        self.reject()
        self.visual = original

    def test_pin_roles_source_mutation_and_disk_mutation(self):
        self.model.write_bytes(b'changed')
        self.reject()
        self.model.write_bytes(b'synthetic native, not executable\n')
        self.expect['pins'].pop(str(self.run / 'python/run_quake_standard.py'))
        self.persist()
        self.reject()

    def test_closed_disk_and_frame_changes_rejected(self):
        (self.run / 'guest.vhd').write_bytes(b'changed closed disk')
        self.reject()
        (self.run / 'guest.vhd').write_bytes(b'mocked closed disk bytes\n')
        self.frame.write_bytes(self.frame.read_bytes()[:-1])
        self.reject()

    def test_missing_final_receipt_and_unexpected_extra_raw_frame(self):
        path = self.run / 'receipt-final.json'
        original = path.read_bytes()
        path.unlink()
        self.reject()
        path.write_bytes(original)
        (self.run / 'frame_99999.ppm').write_bytes(self.frame.read_bytes())
        self.reject()

    def test_admission_cold_environment_and_resource_negative_matrix(self):
        original_before, original_final = copy.deepcopy(self.before), copy.deepcopy(self.final)
        for key, bad in [('memory.max', 'max'), ('memory.swap.max', '1'), ('pids.max', '160'),
                         ('cpu.max', 'max 100000'), ('memory.events', 'oom 0\noom_kill 1\noom_group_kill 0'),
                         ('memory.events.local', 'oom 0'), ('cgroup.procs', str(self.owner) + '\n2')]:
            with self.subTest(key=key):
                self.final = copy.deepcopy(original_final)
                self.final['cgroup_files'][key] = bad
                self.persist()
                self.reject()
        self.before, self.final = original_before, original_final
        self.before['environment']['VEN_GUEST_PATCH'] = '1'
        self.persist()
        self.reject()

    def test_native_admission_changed_even_if_rehashed(self):
        self.admission['affinity'] = [15]
        self.result['native_admission'] = self.admission
        self.persist()
        self.reject()

    def test_duplicate_json_nonfinite_schema_bool_and_symlink(self):
        path = self.run / 'result.json'
        original = path.read_bytes()
        for suffix in (b',"schema":1}', b',"unused":NaN}'):
            path.write_bytes(original.rstrip()[:-1] + suffix)
            self.reject()
        path.write_bytes(original)
        self.result['schema'] = True
        self.write(path, self.result)
        self.reject()
        path.unlink()
        path.symlink_to(self.run / 'receipt-before.json')
        self.reject()

    def test_real_disk_reader_refuses_fixture_size(self):
        with self.assertRaises(ValueError):
            gate.Files().digest_disk(self.run / 'guest.vhd')

    def test_external_sha_authorities_required_by_cli(self):
        expectation, visual, closure = self.build / 'expect.json', self.build / 'visual.json', self.build / 'supervisor.json'
        self.write(expectation, self.expect)
        self.write(visual, self.visual)
        self.write(closure, self.supervisor)
        argv = ['checker', str(self.run), '--expect', str(expectation), '--expect-sha256', sha(expectation),
                '--visual-review', str(visual), '--visual-review-sha256', sha(visual), '--supervisor-closure', str(closure)]
        for extra in ([], ['--supervisor-sha256', '0' * 64]):
            with self.subTest(extra=extra), patch('sys.argv', argv + extra), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as result:
                    gate.main()
                self.assertEqual(result.exception.code, 2)
        with patch('sys.argv', argv + ['--supervisor-sha256', sha(closure)]), redirect_stdout(io.StringIO()), \
                patch.object(gate.Files, 'digest_disk', lambda _files, path: sha(path)):
            self.assertEqual(gate.main(), 0)


if __name__ == '__main__':
    unittest.main()
