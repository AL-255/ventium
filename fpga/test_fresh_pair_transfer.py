"""Enforce the exact tested L1 delta when transferring to PC and FPGA inputs."""
from pathlib import Path
import unittest

import build_fresh_pair_soc as native
import freeze_fresh_pair_rk_candidate as freeze

ROOT = Path('/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI').resolve(strict=True)


class TransferTests(unittest.TestCase):
    def setUp(self):
        self.assertEqual(native.CHANGES, ['rtl/mem/ven_l1d.sv'])
        self.name = native.CHANGES[0]
        self.before = (ROOT/'read-owner-soc-r1/source'/self.name).read_bytes()
        self.after = (ROOT/'fresh-pair-core-r1/candidate'/self.name).read_bytes()

    def test_actual_core_and_export_change_agree(self):
        self.assertEqual(native.transformed(self.before.decode(),self.name).encode(),self.after)
        self.assertTrue(freeze.check_delta('ventium/'+self.name,self.before,self.after))

    def test_required_change_cannot_be_omitted(self):
        with self.assertRaises(Exception):
            freeze.check_delta('ventium/'+self.name,self.before,self.before)

    def test_no_extra_bytes(self):
        with self.assertRaises(Exception):
            freeze.check_delta('ventium/'+self.name,self.before,self.after+b'\n')

    def test_parent_drift_rejected(self):
        with self.assertRaises(ValueError):
            native.transformed(self.before.decode()+'\n',self.name)

    def test_reapplication_rejected(self):
        with self.assertRaises(ValueError):
            native.transformed(self.after.decode(),self.name)

    def test_unrelated_payload_unchanged(self):
        name='ventium/rtl/core/decode.sv'
        self.assertFalse(freeze.check_delta(name,b'unchanged',b'unchanged'))
        with self.assertRaises(Exception):
            freeze.check_delta(name,b'unchanged',b'changed')


if __name__=='__main__': unittest.main()
