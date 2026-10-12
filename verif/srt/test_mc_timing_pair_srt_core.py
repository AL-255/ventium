"""Receipt admission checks; not native SRT or processor verification."""
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import build_mc_timing_pair_srt_core as builder

check_evidence = builder.check_evidence


def evidence(mode):
    labels = [('positive-build', 0), ('positive', 0),
              ('bad-sqrt-build', 0), ('bad-sqrt', 1)] if mode == 'engine' else [
        ('positive-proof', 0), ('positive-build', 0), ('positive', 0),
        ('wrong-zero-proof', 0), ('wrong-zero-build', 0), ('wrong-zero', 1),
        ('wrong-half-proof', 0), ('wrong-half-build', 0), ('wrong-half', 1)]
    return dict(passed=True, pins_unchanged=True, errors=[], mode=mode,
                whole_core=False, rows=[dict(label=k, native_exit=v) for k, v in labels])


class Admission(unittest.TestCase):
    def test_expected_leaf_receipts(self):
        check_evidence(evidence('engine'), evidence('helper'))

    def test_failed_or_wrong_scope_receipts_rejected(self):
        for which in range(2):
            for key, value in [('passed', False), ('pins_unchanged', False),
                               ('errors', ['failure']), ('mode', 'wrong'), ('whole_core', True)]:
                with self.subTest(which=which, key=key):
                    rows = [evidence('engine'), evidence('helper')]
                    rows[which][key] = value
                    with self.assertRaises(AssertionError):
                        check_evidence(*rows)

    def test_every_missing_native_result_rejected(self):
        original = [evidence('engine'), evidence('helper')]
        for which in range(2):
            for index in range(len(original[which]['rows'])):
                with self.subTest(which=which, index=index):
                    rows = copy.deepcopy(original)
                    rows[which]['rows'].pop(index)
                    with self.assertRaises(AssertionError):
                        check_evidence(*rows)

    def test_every_wrong_native_exit_rejected(self):
        original = [evidence('engine'), evidence('helper')]
        for which in range(2):
            for index in range(len(original[which]['rows'])):
                with self.subTest(which=which, index=index):
                    rows = copy.deepcopy(original)
                    rows[which]['rows'][index]['native_exit'] ^= 1
                    with self.assertRaises(AssertionError):
                        check_evidence(*rows)

    def test_build_refuses_unowned_lock_before_launch(self):
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        self.assertEqual(Path(os.environ['TMPDIR']).resolve(), scratch)
        with tempfile.TemporaryDirectory(prefix='mc-pair-srt-test-', dir=scratch) as folder:
            root = Path(folder)
            (root/'prepared.json').write_text(json.dumps({}))
            with patch.dict(os.environ, {'INVOCATION_ID': '0'*32}), \
                 patch.object(builder.subprocess, 'run',
                              side_effect=subprocess.CalledProcessError(1, 'guard')) as native:
                with self.assertRaises(subprocess.CalledProcessError):
                    builder.build(root)
            self.assertEqual(native.call_count, 1)
            self.assertEqual(native.call_args.args[0][-1], '--is-active')
            self.assertEqual(native.call_args.kwargs['pass_fds'], (9,))
            self.assertFalse((root/'build-started.json').exists())

    def test_build_reapplication_rejects_before_launch(self):
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        with tempfile.TemporaryDirectory(prefix='mc-pair-srt-test-', dir=scratch) as folder:
            root = Path(folder)
            (root/'prepared.json').write_text(json.dumps({}))
            (root/'build-started.json').write_text(json.dumps({}))
            with patch.object(builder.subprocess, 'run') as native:
                with self.assertRaises(AssertionError):
                    builder.build(root)
            native.assert_not_called()


if __name__ == '__main__':
    unittest.main()
