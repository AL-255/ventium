"""Fail closed on source drift and preserve the original bus-control equations."""
from pathlib import Path
import unittest

import prepare_early_bus_payload as recipe

SOURCE = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/decode-bus-core-r1/candidate')/recipe.FILE


class EarlyBusPayload(unittest.TestCase):
    def test_exact_synthesized_change(self):
        old = SOURCE.read_text()
        new = recipe.transform(old)
        debug = recipe.shadow(old)
        self.assertTrue(new.endswith(debug))
        synthesis = new[:-len(debug)]
        self.assertEqual(synthesis.replace(recipe.EARLY, recipe.INITIAL)
                         .replace(recipe.COMMENT, recipe.predecessor.NEW), old)
        self.assertNotIn('if (fe_translatable || state == S_DECODE)', synthesis)
        self.assertEqual(recipe.physical_arms(old), recipe.PHYSICAL)

    def test_shadow_is_complete_original_driver(self):
        old = SOURCE.read_text()
        body = recipe.shadow(old)
        for name in recipe.OUTPUTS:
            body = body.replace('bus_payload_ref_'+name, name)
        self.assertIn(recipe.driver(old), body)
        self.assertIn('if (bd_req || bd_req || fe_translatable)', body)
        self.assertIn('EARLY-BUS-PAYLOAD: consumed address changed', body)

    def test_source_drift_and_reapplication_rejected(self):
        old = SOURCE.read_text()
        for text in (old+'\n', recipe.transform(old), old.replace('S_RMIRET:', 'S_RMIRET_X:')):
            with self.assertRaises(ValueError): recipe.transform(text)


if __name__ == '__main__':
    unittest.main()
