#!/usr/bin/env python3
"""Host orchestration fault-injection tests; no RTL or guest execution."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import stat
import tempfile
import unittest
from unittest.mock import patch

import run_state_delta_capture as capture


class CaptureTests(unittest.TestCase):
    def exercise(self, mismatch=None, final_bundle_failure=False, readonly=False):
        with tempfile.TemporaryDirectory(prefix='ventium-capture-test.') as directory:
            root = Path(directory)
            bundle, obj, work = (root / name for name in ('bundle', 'obj', 'work'))
            for path in (bundle, obj, work):
                path.mkdir()
            for name in ('gameplay.snap', 'guest.vhd', 'ao486sim_ven'):
                (bundle / name).write_bytes(b'frozen-source')
            if readonly:
                (bundle / 'guest.vhd').chmod(0o444)
            for name in ('ao486sim_ven', 'ven_state_fields.inc',
                         'ven_state_fields.audit.json', 'Vsystem__verFiles.dat',
                         'Vsystem__ALL.a'):
                (obj / name).write_bytes(b'profiler-fixture')
            runs, checks = [], []

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
                if readonly:
                    self.assertEqual(stat.S_IMODE((bundle / 'guest.vhd').stat().st_mode), 0o444)
                phase = destination.parent.name
                runs.append(phase)
                if phase == 'reference':
                    self.assertEqual(Path(argv[0]), bundle / 'ao486sim_ven')
                    self.assertNotIn('--ven-delta-out', argv)
                else:
                    self.assertEqual(Path(argv[0]), work / 'profiler')
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
            expected_error = (RuntimeError if mismatch else
                              subprocess.CalledProcessError if final_bundle_failure else None)
            with patch('sys.argv', argv), patch.dict(os.environ, TMPDIR=str(root)), \
                    patch.object(capture.tempfile, 'mkdtemp', return_value=str(work)), \
                    patch.object(capture.subprocess, 'run', side_effect=fake_run), \
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
            self.assertEqual(success, not mismatch and not final_bundle_failure)
            self.assertEqual(len(checks), 1 if mismatch else 2)
            for path in bundle.iterdir():
                self.assertEqual(path.read_bytes(), b'frozen-source')

    def test_success(self):
        self.exercise()

    def test_readonly_bundle_private_disks_are_writable(self):
        self.exercise(readonly=True)

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


if __name__ == '__main__':
    unittest.main()
