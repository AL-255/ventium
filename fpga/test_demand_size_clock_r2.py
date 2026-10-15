"""Clock retry must change identity only, never the resource or timing gates."""
from pathlib import Path
import unittest

import prepare_demand_size_clock_r2 as retry


class Retry(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path('/home/yukidama/external/tmp') / retry.ROOT_NAME / 'demand-size-clock-r1'
        cls.original = {name: (root / name).read_text() for name in retry.HASHES}

    def test_identity_only(self):
        output = retry.derive(self.original)
        self.assertEqual(output['audit.tcl'], self.original['audit.tcl'])
        for name in ('run.py', 'audit_closed.py'):
            self.assertEqual(output[name].replace(retry.NEW_UNIT, retry.OLD_UNIT),
                             self.original[name])
        for clause in ("host['MemAvailable'] > 10*gib", "host['SwapFree'] > 8*gib",
                       "VENTIUM_VIVADO_MEMORY_MAX='8G'", 'process.wait(timeout=90)',
                       "elif min(host.values()) < 2*gib:", "if free < 4*gib:"):
            self.assertIn(clause, output['run.py'])

    def test_reapplication_rejected(self):
        with self.assertRaises(ValueError):
            retry.derive(retry.derive(self.original))

    def test_changed_limits_or_reports_rejected(self):
        for name, old, new in (
            ('run.py', "host['MemAvailable'] > 10*gib", "host['MemAvailable'] > 2*gib"),
            ('run.py', "VENTIUM_VIVADO_MEMORY_MAX='8G'", "VENTIUM_VIVADO_MEMORY_MAX='16G'"),
            ('audit.tcl', 'report_timing_summary', '# report_timing_summary'),
            ('audit_closed.py', "'black_boxes=0 structural_errors=0'", "'black_boxes=0'"),
        ):
            changed = dict(self.original)
            self.assertIn(old, changed[name])
            changed[name] = changed[name].replace(old, new)
            with self.assertRaises(ValueError):
                retry.derive(changed)


if __name__ == '__main__':
    unittest.main()
