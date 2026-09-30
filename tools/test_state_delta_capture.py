#!/usr/bin/env python3
"""Host orchestration fault-injection tests; no RTL or guest execution."""
import contextlib
import gzip
import io
import json
import os
from pathlib import Path
import subprocess
import stat
import struct
import tempfile
import unittest
from unittest.mock import patch

import run_state_delta_capture as capture


def generated_makefile(target):
    return (f'default: {target}\n\n'
            f'{target}: $(VK_USER_OBJS) $(VK_GLOBAL_OBJS) $(VM_PREFIX)__ALL.a\n'
            '\t$(LINK) $(LDFLAGS) $^ $(LOADLIBES) $(LDLIBS) '
            '$(LIBS) $(SC_LIBS) -o $@\n')


def profiler_fixture(obj, target='ao486sim_ven', coexisting=False):
    (obj/'Vsystem.mk').write_text(generated_makefile(target))
    for name in (target, 'ven_state_fields.inc', 'ven_state_fields.audit.json',
                 'Vsystem__verFiles.dat', 'Vsystem__ALL.a',
                 'Vsystem___024root.h', 'Vsystem___024root__Slow.cpp',
                 'Vsystem__Syms.h'):
        (obj/name).write_bytes(('profiler-fixture ' + name).encode())
    (obj/target).chmod(0o755)
    if coexisting:
        other = 'ao486sim_ven' if target == 'ao486sim_ven_standard' else 'ao486sim_ven_standard'
        (obj/other).write_bytes(b'stale-coexisting-executable')
        (obj/other).chmod(0o755)
    model = [*obj.glob('Vsystem*.h'), *obj.glob('Vsystem*.cpp'), obj/'Vsystem__ALL.a']
    receipt = dict(model_unchanged=True, host_object_rebuilt=True,
                   executable_relinked=True, executable=target,
                   profiler_sha256=capture.sha(obj/target),
                   model_hashes={p.name:capture.sha(p) for p in model})
    (obj/'ven_state_relink.json').write_text(json.dumps(receipt))
    return receipt


class CaptureTests(unittest.TestCase):
    def exercise(self, mismatch=None, final_bundle_failure=False, readonly=False,
                 snapshot_version=3, mouse=False, target='ao486sim_ven', coexisting=False,
                 reader_failure=None):
        with tempfile.TemporaryDirectory(prefix='ventium-capture-test.') as directory:
            root = Path(directory)
            bundle, obj, work = (root / name for name in ('bundle', 'obj', 'work'))
            for path in (bundle, obj, work):
                path.mkdir()
            for name in ('gameplay.snap', 'guest.vhd', 'ao486sim_ven'):
                (bundle / name).write_bytes(b'frozen-source')
            if readonly:
                (bundle / 'guest.vhd').chmod(0o444)
            receipt = profiler_fixture(obj, target, coexisting)
            runs, checks = [], []
            reads = []

            def fake_validate(path, start, count):
                reads.append((path.parent.name, start, count))
                self.assertEqual(start, 1300000000)
                self.assertEqual(count, 1000 if path.parent.name == 'pilot' else 1000000)
                if path.parent.name == 'on' and reader_failure:
                    raise ValueError(f'full reader failure: {reader_failure}')

            def fake_run(argv, **kwargs):
                if argv[0] == 'python3':
                    script = Path(argv[1]).name
                    if script == 'checkpoint_bundle.py':
                        checks.append(script)
                        if final_bundle_failure and len(checks) == 2:
                            raise subprocess.CalledProcessError(1, argv)
                    else:
                        self.assertEqual(script, 'state_delta_read.py')
                    return subprocess.CompletedProcess(argv, 0)
                destination = Path(argv[argv.index('--save-file') + 1])
                private_disk = Path(argv[argv.index('--ide') + 1])
                self.assertTrue(private_disk.stat().st_mode & stat.S_IWUSR)
                self.assertEqual(argv.count(f'--snapshot-v{snapshot_version}'), 1)
                self.assertNotIn('--snapshot-v4' if snapshot_version == 3 else
                                 '--snapshot-v3', argv)
                self.assertEqual(argv.count('--mouse'), int(mouse))
                for flag, expected in (('--rate', '45000000'),
                                       ('--rate-rtc', '45000000'),
                                       ('--rate-vga', '90000000'), ('--mem', '32')):
                    self.assertEqual(argv[argv.index(flag) + 1], expected)
                self.assertEqual(kwargs['env']['FPGA_DDR'], '2')
                self.assertEqual(kwargs['env']['AO486_RTC_EPOCH'], '1789257600')
                if readonly:
                    self.assertEqual(stat.S_IMODE((bundle / 'guest.vhd').stat().st_mode), 0o444)
                phase = destination.parent.name
                runs.append(phase)
                if phase == 'reference':
                    self.assertEqual(Path(argv[0]), bundle / 'ao486sim_ven')
                    self.assertNotIn('--ven-delta-out', argv)
                else:
                    self.assertEqual(Path(argv[0]), work / 'profiler')
                    self.assertEqual(capture.sha(work/'profiler'), receipt['profiler_sha256'])
                # Equal terminal cycle must yield equal state/disk. Deliberate
                # mutations below model relink drift or observer interference.
                end = argv[argv.index('--save-at') + 1].encode()
                for name in ('end.snap', 'guest.vhd'):
                    value = name.encode() + end
                    if mismatch == (phase, name):
                        value += b'CORRUPTION'
                    (destination.parent / name).write_bytes(value)
                return subprocess.CompletedProcess(argv, 0)

            output = io.StringIO()
            argv = ['capture', str(bundle), str(obj), '--start', '1300000000']
            if snapshot_version != 3:
                argv += ['--snapshot-version', str(snapshot_version)]
            if mouse:
                argv += ['--mouse']
            expected_error = (RuntimeError if mismatch else
                              subprocess.CalledProcessError if final_bundle_failure else
                              ValueError if reader_failure else None)
            with patch('sys.argv', argv), patch.dict(os.environ, TMPDIR=str(root)), \
                    patch.object(capture.tempfile, 'mkdtemp', return_value=str(work)), \
                    patch.object(capture.subprocess, 'run', side_effect=fake_run), \
                    patch.object(capture, 'validate_trace', side_effect=fake_validate), \
                    contextlib.redirect_stdout(output):
                if expected_error:
                    with self.assertRaises(expected_error):
                        capture.main()
                else:
                    capture.main()
            source_bad = mismatch and mismatch[0] == 'reference'
            self.assertEqual(runs, ['pilot', 'reference'] if source_bad else
                             ['pilot', 'reference', 'off', 'on'])
            receipt = json.loads((work / 'host_relink_check.json').read_text())
            self.assertEqual(all(row['identical'] for row in receipt.values()), not source_bad)
            success = 'STATE-DELTA-OBSERVER-OK' in output.getvalue()
            self.assertEqual(success, not mismatch and not final_bundle_failure and not reader_failure)
            self.assertEqual(len(checks), 1 if mismatch or reader_failure else 2)
            expected_reads = [('pilot', 1300000000, 1000)]
            if not source_bad:
                expected_reads.append(('on', 1300000000, 1000000))
            self.assertEqual(reads, expected_reads)
            for path in bundle.iterdir():
                self.assertEqual(path.read_bytes(), b'frozen-source')

    def test_success(self):
        self.exercise()

    def test_readonly_bundle_private_disks_are_writable(self):
        self.exercise(readonly=True)

    def test_v4_mouse_forwarded_to_all_four_invocations(self):
        self.exercise(snapshot_version=4, mouse=True)

    def test_v4_without_mouse_forwarded_to_all_four_invocations(self):
        self.exercise(snapshot_version=4)

    def test_standard_only_target_selected(self):
        self.exercise(snapshot_version=4, mouse=True, target='ao486sim_ven_standard')

    def test_stale_legacy_does_not_replace_standard_target(self):
        self.exercise(target='ao486sim_ven_standard', coexisting=True)

    def test_stale_standard_does_not_replace_legacy_target(self):
        self.exercise(coexisting=True)

    def reject_profiler(self, change):
        with tempfile.TemporaryDirectory(prefix='ventium-capture-receipt-test.') as directory:
            obj = Path(directory)/'obj'
            obj.mkdir()
            receipt = profiler_fixture(obj, target='ao486sim_ven_standard', coexisting=True)
            change(obj, receipt)
            argv = ['capture', '/nonexistent/bundle', str(obj), '--start', '393900000']
            with patch('sys.argv', argv), \
                    patch.object(capture.subprocess, 'run') as run, \
                    patch.object(capture.tempfile, 'mkdtemp') as mkdtemp, \
                    patch.object(capture.shutil, 'copy2') as copy, \
                    contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:
                    capture.main()
            self.assertEqual(caught.exception.code, 2)
            run.assert_not_called()
            mkdtemp.assert_not_called()
            copy.assert_not_called()

    def test_missing_relink_receipt_rejected_before_staging(self):
        self.reject_profiler(lambda obj, _receipt: (obj/'ven_state_relink.json').unlink())

    def test_wrong_profiler_hash_rejected_before_staging(self):
        def change(obj, receipt):
            receipt['profiler_sha256'] = '0'*64
            (obj/'ven_state_relink.json').write_text(json.dumps(receipt))
        self.reject_profiler(change)

    def test_stale_legacy_receipt_rejected_before_staging(self):
        def change(obj, receipt):
            receipt.update(executable='ao486sim_ven', profiler_sha256=capture.sha(obj/'ao486sim_ven'))
            (obj/'ven_state_relink.json').write_text(json.dumps(receipt))
        self.reject_profiler(change)

    def test_missing_relink_proofs_rejected_before_staging(self):
        for field in ('model_unchanged', 'host_object_rebuilt', 'executable_relinked'):
            with self.subTest(field=field):
                def change(obj, receipt):
                    receipt[field] = False
                    (obj/'ven_state_relink.json').write_text(json.dumps(receipt))
                self.reject_profiler(change)

    def test_changed_model_rejected_before_staging(self):
        self.reject_profiler(lambda obj, _receipt: (obj/'Vsystem__ALL.a').write_bytes(b'changed-model'))

    def test_injected_generated_target_rejected_before_staging(self):
        self.reject_profiler(lambda obj, _receipt: (obj/'Vsystem.mk').write_text(
            generated_makefile('../unsafe')))

    def reject_v3_mouse(self, explicit_version=False):
        argv = ['capture', '/nonexistent/bundle', '/nonexistent/obj',
                '--start', '1300000000', '--mouse']
        if explicit_version:
            argv += ['--snapshot-version', '3']
        error = io.StringIO()
        with patch('sys.argv', argv), \
                patch.object(capture.subprocess, 'run') as run, \
                patch.object(capture.tempfile, 'mkdtemp') as mkdtemp, \
                patch.object(capture.shutil, 'copy2') as copy, \
                contextlib.redirect_stderr(error):
            with self.assertRaises(SystemExit) as caught:
                capture.main()
        self.assertEqual(caught.exception.code, 2)
        self.assertIn('--mouse requires --snapshot-version 4', error.getvalue())
        run.assert_not_called()
        mkdtemp.assert_not_called()
        copy.assert_not_called()

    def test_default_v3_mouse_rejected_before_any_launch_or_staging(self):
        self.reject_v3_mouse()

    def test_explicit_v3_mouse_rejected_before_any_launch_or_staging(self):
        self.reject_v3_mouse(explicit_version=True)

    def test_frozen_snapshot_drift_stops_before_full_capture(self):
        self.exercise(('reference', 'end.snap'))

    def test_frozen_disk_drift_stops_before_full_capture(self):
        self.exercise(('reference', 'guest.vhd'))

    def test_observer_snapshot_drift_fails(self):
        self.exercise(('on', 'end.snap'))

    def test_observer_disk_drift_fails(self):
        self.exercise(('on', 'guest.vhd'))

    def test_source_bundle_changed_at_end_fails(self):
        self.exercise(final_bundle_failure=True)

    def test_full_truncated_trace_suppresses_success(self):
        self.exercise(reader_failure='truncated')

    def test_full_corrupt_trace_suppresses_success(self):
        self.exercise(reader_failure='corrupt')

    def test_full_reader_failure_suppresses_success(self):
        self.exercise(reader_failure='reader failed')


class TraceValidationTests(unittest.TestCase):
    def trace_bytes(self, start=393900000, count=3):
        name, typ = b'value', b'uint32_t'
        payload = (b'VENDLT01' + struct.pack('<IQQI', 1, start, count, 4)
                   + struct.pack('<I', len(name)) + name
                   + struct.pack('<I', len(typ)) + typ + struct.pack('<I', 4)
                   + bytes(4))
        for index in range(1, count + 1):
            payload += (struct.pack('<QI', start + index, 1)
                        + struct.pack('<IH', 0, 1) + bytes((index,)))
        return payload + b'ENDDLT01' + struct.pack('<Q', count) + bytes((count, 0, 0, 0))

    def check(self, payload, *, start=393900000, count=3, error=False):
        with tempfile.TemporaryDirectory(prefix='ventium-capture-reader-test.') as directory:
            path = Path(directory)/'trace.gz'
            with gzip.open(path, 'wb') as stream:
                stream.write(payload)
            with contextlib.redirect_stdout(io.StringIO()) as output:
                if error:
                    with self.assertRaises(ValueError):
                        capture.validate_trace(path, start, count)
                    self.assertNotIn('STATE-DELTA-READ-OK', output.getvalue())
                else:
                    capture.validate_trace(path, start, count)
                    self.assertIn('STATE-DELTA-READ-OK cycles=3', output.getvalue())

    def test_complete_trace_and_full_terminal_reconstruction(self):
        self.check(self.trace_bytes())

    def test_truncated_terminal_rejected(self):
        self.check(self.trace_bytes()[:-1], error=True)

    def test_corrupt_completion_footer_rejected(self):
        self.check(self.trace_bytes().replace(b'ENDDLT01', b'BADDLT01'), error=True)

    def test_corrupt_full_terminal_reconstruction_rejected(self):
        payload = self.trace_bytes()
        self.check(payload[:-4] + bytes((99, 0, 0, 0)), error=True)

    def test_requested_start_mismatch_rejected(self):
        self.check(self.trace_bytes(), start=393900001, error=True)

    def test_requested_count_mismatch_rejected(self):
        self.check(self.trace_bytes(), count=4, error=True)


if __name__ == '__main__':
    unittest.main()
