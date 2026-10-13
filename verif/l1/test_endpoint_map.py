"""Recipe and extraction guard tests; not native RTL acceptance."""
import os
from pathlib import Path
import unittest

import prepare_endpoint_map as recipe


class EndpointMap(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (Path(os.environ['ENDPOINT_MAP_PARENT']) / recipe.FILE).read_text()

    def test_reject_drift_and_reapplication(self):
        for source in (self.source+'\n', recipe.transform(self.source)):
            with self.assertRaisesRegex(ValueError, 'drift/reapplication'):
                recipe.transform(source)

    def test_only_three_exact_edits(self):
        changed = recipe.transform(self.source)
        # Reverse the empty PCI deletion at its original adjacent first-map anchor.
        for old, new in reversed(recipe.edits()):
            if new:
                self.assertEqual(changed.count(new), 1)
                changed = changed.replace(new, old)
            else:
                anchor = "                            || (core_addr    >= 32'hFFFE_0000) );\n"
                self.assertEqual(changed.count(anchor+'\n'), 1)
                changed = changed.replace(anchor+'\n', anchor+old+'\n')
        self.assertEqual(changed, self.source)

    def test_preserve_extent_permissions_and_all_state(self):
        changed = recipe.transform(self.source)
        for line in self.source.splitlines():
            if any(key in line for key in ('assign core_d_last =', 'assign core_route_deny =',
                   'assign l1d_c_req =', 'assign core_ack =', 'assign l1d_cacheable =',
                   'assign core_store_pair_ready =')):
                self.assertEqual(changed.count(line), self.source.count(line))
        # The only new edge-triggered blocks are observers, excluded in synthesis.
        self.assertEqual(changed.count('always_ff'), self.source.count('always_ff')+2)
        self.assertIn("if ((ADDR_MASK & 32'h1f) == 32'h1f)", changed)
        self.assertIn('g_byte_endpoint_route', changed)
        self.assertIn("core_addr[31:5] + 27'd1", changed)


if __name__ == '__main__':
    unittest.main()
