"""The architectural policy experiment may add one define and nothing else."""
import json
from pathlib import Path
import unittest
import build_strict_mf_core as build


class StrictPolicy(unittest.TestCase):
    def setUp(self):
        root = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/branch-address-core-r1')
        self.command = json.loads((root/'build-started.json').read_text())['command']

    def test_only_define_added(self):
        after, definitions = build.enable(self.command)
        self.assertEqual(len(definitions), 153)
        self.assertEqual(definitions[-1], 'VEN_X87_MF_STRICT')
        self.assertEqual([s.removesuffix(' +define+VEN_X87_MF_STRICT') for s in after], self.command)

    def test_reject_changed_profile(self):
        after, _ = build.enable(self.command)
        with self.assertRaises(AssertionError):
            build.enable(after)
        with self.assertRaises(AssertionError):
            build.enable([s.replace('--assert', '') for s in self.command])
        with self.assertRaises(AssertionError):
            build.enable([s.replace('-GAXI_LINE_REPLAY=0', '-GAXI_LINE_REPLAY=1') for s in self.command])


if __name__ == '__main__':
    unittest.main()
