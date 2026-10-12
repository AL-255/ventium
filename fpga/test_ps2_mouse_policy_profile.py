"""Fail-closed selection of the actual FPGA 8042 profile for the wire test."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    'ps2_policy_gate', Path(__file__).with_name('run-ps2-mouse-policy-gate.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class ProfileTests(unittest.TestCase):
    source = '`ifdef VEN_KBC_FAST\n`endif\n`ifdef VEN_KBD_AUTOACK\n`endif\n'
    profile = 'VEN_CORE\nVEN_KBC_FAST\nVEN_KBD_AUTOACK\nVEN_L2_SETS=1024\n'

    def test_only_controller_features_selected(self):
        self.assertEqual(gate.kbc_defines(self.source, self.profile),
                         ['VEN_KBC_FAST', 'VEN_KBD_AUTOACK'])

    def test_unknown_source_branch_rejected(self):
        with self.assertRaises(AssertionError):
            gate.kbc_defines(self.source+'`ifndef VEN_NEW_KBC\n', self.profile)

    def test_missing_valued_duplicate_or_unsafe_define_rejected(self):
        cases = (self.profile.replace('VEN_KBC_FAST\n', ''),
                 self.profile.replace('VEN_KBC_FAST\n', 'VEN_KBC_FAST=0\n'),
                 self.profile+'VEN_CORE\n', self.profile+'VEN_CORE=1\n',
                 self.profile+'-o bad\n')
        for value in cases:
            with self.subTest(value=value), self.assertRaises(AssertionError):
                gate.kbc_defines(self.source, value)


if __name__ == '__main__':
    unittest.main()
