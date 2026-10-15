"""Host checks of the composed transfer and actual nested derivation."""
from pathlib import Path
import unittest

import build_fetch_pair_next_soc as native
import freeze_fetch_pair_next_rk_candidate as freeze


class Transfer(unittest.TestCase):
    def test_profile(self):
        self.assertEqual(native.CHANGES, sorted(native.recipe.PARENTS))
        self.assertEqual(len(native.CHANGES), 4)
        self.assertEqual(native.CORE_MODEL, '8eaf19eddc32b69549842d52b9b2f5865ea23962d3a520a2a8a660854e1c79d1')
        self.assertEqual(freeze.CHANGES, ['ventium/' + n for n in native.CHANGES])
        self.assertIn("tooling_deltas = {}", native.derived)
        self.assertNotIn('tooling.qualify_tooling(pins)', native.derived)
        self.assertIn("first_v_pairs']==72", native.derived)

    def test_exact_deltas(self):
        parent = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X/prefix-payload-soc-r1/source')
        core = parent.parents[1] / 'fetch-pair-next-core-r1/candidate'
        for name in native.CHANGES:
            before, after = (parent / name).read_bytes(), (core / name).read_bytes()
            self.assertEqual(native.transform(name, before.decode()).encode(), after)
            self.assertTrue(freeze.check_delta('ventium/' + name, before, after))
            with self.assertRaises(Exception):
                freeze.check_delta('ventium/' + name, before, before)
            with self.assertRaises(Exception):
                freeze.check_delta('ventium/' + name, before, after + b'\n')
        with self.assertRaises(Exception):
            freeze.check_delta('ventium/rtl/unreviewed.sv', b'a', b'b')


if __name__ == '__main__':
    unittest.main()
