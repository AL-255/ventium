"""Exact four-file hardware recipe and normal timing-driven source contract."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import freeze_prime_noack_rk_candidate as export


class SourceContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path(os.environ['PRIME_FPGA_PARENT']).resolve(strict=True)
        cls.sources = {name: (cls.parent/name).read_text() for name in export.CHANGES}

    def test_exact_four_outputs(self):
        values = export.expected_payloads(self.sources)
        self.assertEqual({p: export.sha256(v) for p, v in values.items()}, export.CHANGES)

    def test_drift_and_reapplication_rejected(self):
        result = export.expected_payloads(self.sources)
        for path in export.CHANGES:
            for replacement in (self.sources[path]+'\n', result[path].decode()):
                changed = dict(self.sources); changed[path] = replacement
                with self.assertRaises(ValueError): export.expected_payloads(changed)

    def test_balanced_wrapper_does_not_disable_timing_optimization(self):
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        self.assertEqual(Path(os.environ['TMPDIR']).resolve(), scratch)
        with tempfile.TemporaryDirectory(prefix='ventium-prime-wrapper-', dir=scratch) as temp:
            shutil.copytree(self.parent/'flow', temp, dirs_exist_ok=True)
            command = ['tclsh', str(export.REPO/'fpga/test_code_payload_rk_wrapper.tcl'),
                str(self.parent/'ventium/fpga/create_project_3mhz_wrapper.tcl'), temp,
                str(self.parent/'defines.txt'), str(self.parent/'ventium'),
                str(self.parent/'template'), 'balanced']
            done = subprocess.run(command, capture_output=True, text=True, timeout=15)
        self.assertEqual(done.returncode, 0, done.stdout+done.stderr)
        self.assertIn('exact156defs', done.stdout)
        self.assertIn('POSTED-DDR-SOURCE-CONTRACT-OK', done.stdout)


if __name__ == '__main__':
    unittest.main()
