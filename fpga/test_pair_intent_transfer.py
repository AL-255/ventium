"""Check exact parent/core/PC/FPGA arbitration deltas and reject byte drift."""
from pathlib import Path
import unittest

import build_pair_intent_soc as native
import freeze_pair_intent_rk_candidate as freeze


ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)


class TransferTests(unittest.TestCase):
    def test_each_declared_change_matches_directed_core(self):
        self.assertEqual(len(native.CHANGES), 5)
        for name in native.CHANGES:
            with self.subTest(name=name):
                before = (ROOT/'backing-payload-soc-r1/source'/name).read_bytes()
                after = (ROOT/'pair-intent-core-r1/candidate'/name).read_bytes()
                self.assertEqual(native.transformed(before.decode(), name).encode(), after)
                self.assertTrue(freeze.check_delta('ventium/'+name, before, after))

    def test_required_change_cannot_be_omitted(self):
        for name in native.CHANGES:
            with self.subTest(name=name), self.assertRaises(Exception):
                before = (ROOT/'backing-payload-soc-r1/source'/name).read_bytes()
                freeze.check_delta('ventium/'+name, before, before)

    def test_no_unreviewed_bytes_in_declared_files(self):
        for name in native.CHANGES:
            with self.subTest(name=name), self.assertRaises(Exception):
                before = (ROOT/'backing-payload-soc-r1/source'/name).read_bytes()
                after = (ROOT/'pair-intent-core-r1/candidate'/name).read_bytes()
                freeze.check_delta('ventium/'+name, before, after+b'\n')

    def test_unrelated_payload_must_be_identical(self):
        name = 'ventium/rtl/core/decode.sv'
        self.assertFalse(freeze.check_delta(name, b'unchanged', b'unchanged'))
        with self.assertRaises(Exception):
            freeze.check_delta(name, b'unchanged', b'changed')


if __name__ == '__main__':
    unittest.main()
