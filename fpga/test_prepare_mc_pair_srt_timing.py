"""Controller derivation tests; no Vivado, generated files or native runs."""
import os
from pathlib import Path
import unittest

import prepare_mc_pair_srt_timing as timing


class TimingControllers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        parent = Path(os.environ['MC_PAIR_SRT_TIMING_PARENT'])
        cls.original = {}
        for name, digest in timing.TEMPLATES.items():
            assert timing.sha(parent/name) == digest
            cls.original[name] = (parent/name).read_text()

    def test_native_lifecycle_and_resource_guards_unchanged(self):
        output = timing.derive(self.original, '0'*32)
        self.assertEqual(len(output), 6)
        for name in ('synthesis', 'clock'):
            old = self.original[name+'-r2/run.py']
            new = output[name+'/run.py']
            self.assertEqual(old.split('owner = None\n')[1], new.split('owner = None\n')[1])
            for guard in ("VENTIUM_VIVADO_MEMORY_MAX='8G'", "VENTIUM_VIVADO_MEMORY_SWAP_MAX='6G'",
                          'if free < 4*gib:', 'memory+swap > 13*gib', 'min(host.values()) < 2*gib'):
                self.assertIn(guard, new)
        self.assertIn('2*measured_disk_growth', output['synthesis/run.py'])

    def test_exact_delta_and_measured_parent(self):
        output = timing.derive(self.original, '0'*32)
        for digest in timing.CHANGES.values():
            self.assertIn(digest, output['synthesis/audit_closed.py'])
        self.assertIn(timing.PARENT, output['synthesis/audit_closed.py'])
        self.assertIn('ventium-mc-read-commit.PNi1O0xm/synthesis-r2', output['clock/run.py'])
        self.assertIn('(-8.802)', output['clock/audit_closed.py'])
        self.assertIn('same_input_regression_passed', output['synthesis/run.py'])
        self.assertIn("not verify['canonical_gate_passed']", output['synthesis/run.py'])

    def test_source_anchor_drift_rejected(self):
        wrong = dict(self.original)
        wrong['synthesis-r2/run.py'] = wrong['synthesis-r2/run.py'].replace(
            "manifest['variant'] == 'mc_read_commit'", "manifest['variant'] == 'other'")
        with self.assertRaises(AssertionError):
            timing.derive(wrong, '0'*32)

    def test_bad_invocation_rejected(self):
        for invocation in ('', '0'*31, 'x'*32):
            with self.assertRaises(AssertionError):
                timing.derive(self.original, invocation)


if __name__ == '__main__':
    unittest.main()
