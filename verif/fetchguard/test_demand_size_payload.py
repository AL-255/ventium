"""Source-scope guards only; these tests do not compile or qualify the RTL."""
from pathlib import Path
import unittest

import prepare_demand_size_payload as recipe

SOURCE = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/early-bus-core-r1/candidate')/recipe.FILE


class DemandSizePayload(unittest.TestCase):
    def test_only_payload_qualification_changes(self):
        old = SOURCE.read_text()
        new = recipe.transform(old)
        debug = recipe.shadow(old)
        self.assertEqual(new.count(debug), 1)
        synthesis = new.replace(debug, '')
        self.assertEqual(synthesis.replace(recipe.NEW, recipe.OLD), old)
        self.assertNotIn('if (sfetch_demand_req)', recipe.block(synthesis))
        self.assertIn('if (sfetch_interior16) sfetch_demand_size = 3\'d4;', synthesis)
        self.assertIn("sfetch_demand_addr[11:0] > 12'hffc", recipe.block(synthesis))

    def test_original_size_and_inactive_authority_are_checked(self):
        old = SOURCE.read_text()
        debug = recipe.shadow(old)
        self.assertIn(recipe.block(old), debug.replace('sfetch_size_ref', 'sfetch_demand_size'))
        self.assertIn('sfetch_demand_size === sfetch_size_ref', debug)
        self.assertIn('!bd_req && !mem_req && !fe_translatable', debug)
        self.assertIn('!perm_fault && !cs_fetch_fault && !fx_start', debug)
        self.assertIn('`ifndef SYNTHESIS', debug)

    def test_drift_and_double_application_fail_closed(self):
        old = SOURCE.read_text()
        for text in (old+'\n', recipe.transform(old),
                     old.replace('sfetch_demand_size = 3\'d4', 'sfetch_demand_size = 3\'d3')):
            with self.assertRaises(ValueError):
                recipe.transform(text)


if __name__ == '__main__':
    unittest.main()
