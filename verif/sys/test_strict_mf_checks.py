"""No comparison or worker-policy change in strict-mode regressions."""
from pathlib import Path
import unittest
import run_strict_mf_checks as checks


class Workers(unittest.TestCase):
    def test_identity_only(self):
        parent = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/branch-address-core-r1').resolve()
        for mode in ('func', 'system'):
            source, original, _ = checks.prior.derive(mode, parent)
            actual_source, after, edits = checks.derive(mode, parent, '1'*64)
            self.assertEqual(source, actual_source)
            recovered = after
            for old, new in reversed(edits[-(4 if mode == 'system' else 1):]):
                self.assertEqual(recovered.count(new), 1)
                recovered = recovered.replace(new, old)
            self.assertEqual(recovered, original)


if __name__ == '__main__':
    unittest.main()
