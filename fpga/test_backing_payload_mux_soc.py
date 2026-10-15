"""Exact source transfer and unchanged native build/profile checks."""
from pathlib import Path
import unittest

import build_backing_payload_mux_soc as native


class Transfer(unittest.TestCase):
    def test_profile_and_preflight(self):
        self.assertEqual(native.CHANGES, ['rtl/mem/ven_l1d.sv'])
        self.assertEqual(native.CORE_MODEL,
            '7c88579767354f269055420cafe3acca089acda87e5ac174b633b3e7905dcdb5')
        for item in ('fresh_qemu', "len(shared) == 102", '156',
                     '-GBOARD_POSTED=1', '-GBOARD_WRITE_SLOTS=16',
                     "canonical_gate_native_exit'] == 2", 'tooling_deltas = {}'):
            self.assertIn(item, native.derived)
        self.assertNotIn('tooling.qualify_tooling(pins)', native.derived)
        self.assertIs(native.base.build, native.previous.base.build)

    def test_exact_source_delta(self):
        root = Path('/home/yukidama/external/tmp/ventium-data-size.v2HaTO2X')
        old = root/'prefix-payload-soc-r1/source'
        new = root/'backing-payload-mux-core-r1/candidate'
        name = native.CHANGES[0]
        self.assertEqual(native.transform(name, (old/name).read_text()), (new/name).read_text())
        with self.assertRaises(ValueError):
            native.transform('rtl/unreviewed.sv', '')
        with self.assertRaises(ValueError):
            native.transform(name, (new/name).read_text())


if __name__ == '__main__':
    unittest.main()
