"""Host-only source/identity guards; no live guest expectation is fabricated."""
import ast
import unittest
from unittest.mock import patch

import freeze_raw_prime_storage_win95_expectation as current


class Expectation(unittest.TestCase):
    def test_native_identity_resource_and_source_checks_retained(self):
        code = current.derive()
        ast.parse(code)
        for token in ("owner == dict(InvocationID=INVOCATION, ActiveState='active'",
                      "MainPID=str(native['ppid'])", "record['starttime']",
                      "os.sched_getaffinity(record['pid'])", "actual_limits['memory.max']",
                      "actual_limits['memory.swap.max'] == '0'", "actual_limits['pids.max'] == '160'",
                      "native['argv'] == before['command']", "sha(native['exe']) == config.MODEL",
                      "all(sha(p) == h for p, h in build['pins'].items())", "before['cold_reset']",
                      "not before['snapshots']", "not before['guest_modifications']",
                      "current.add_lineage(expected, before, root, run)",
                      'desktop_acceptance=False, ui_acceptance=False'):
            self.assertIn(token, code)

    def test_template_drift_is_rejected(self):
        with patch.object(current.previous, 'sha', return_value='wrong-template'):
            with self.assertRaises(AssertionError): current.derive()

    def test_lineage_requires_pins_not_just_paths(self):
        with self.assertRaises(KeyError):
            current.add_lineage({}, {'input_sha256_before': {}}, current.ROOT,
                                current.ROOT/'raw-prime-storage-soc-r1/nonexecuted')


if __name__ == '__main__':
    unittest.main()
