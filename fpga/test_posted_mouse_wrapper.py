import json
import os
from pathlib import Path
import re
import tempfile
import unittest

import repair_posted_mouse_wrapper as fix

PARENT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/v-result-carry-fpga-r1')


def without_devices(text):
    for expression in (r'\bven_ps2_mailbox\s+u_mouse_mailbox\s*\(.*?\);',
                       r'\bven_ps2_device\s*#\(.*?\)\s+u_ps2_mouse_device\s*\(.*?\);'):
        text = re.sub(expression, '', text, flags=re.S)
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)
    return re.findall(r'\S+', text)


class Placement(unittest.TestCase):
    def setUp(self):
        self.before = (PARENT/fix.WRAPPER).read_text()
        self.after = fix.repair(self.before)

    def test_only_the_exact_block_moves(self):
        begin, end = self.before.index(fix.BEGIN), self.before.index(fix.END)
        block = self.before[begin:end]
        self.assertEqual(self.before.replace(block, ''), self.after.replace(block, ''))
        self.assertEqual(self.after.count(block), 1)
        self.assertLess(self.after.index(block), self.after.index(fix.BRANCH))

    def test_input_mutations_and_double_application_rejected(self):
        for bad in (self.after, self.before+'\n', self.before.replace('WRITE_SLOTS(16)', 'WRITE_SLOTS(1)')):
            with self.assertRaises(ValueError): fix.repair(bad)

    def test_real_preprocessor_both_profiles_and_red_control(self):
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        self.assertEqual(Path(os.environ['TMPDIR']).resolve(), scratch)
        self.assertNotEqual(scratch.stat().st_dev, Path('/').stat().st_dev)
        definitions = json.loads((PARENT/'input-manifest.json').read_text())['hardware_defines']
        self.assertEqual(len(definitions), 159)
        with tempfile.TemporaryDirectory(prefix='posted-mouse-contract-', dir=scratch) as directory:
            corrected = Path(directory)/'fixed.v'; corrected.write_text(self.after)
            for posted in (True, False):
                defs = definitions if posted else [n for n in definitions if n != 'VEN_DDR_POSTED']
                old = fix.preprocess(PARENT/fix.WRAPPER, defs)
                new = fix.preprocess(corrected, defs)
                fix.check_devices(new)
                if posted:
                    with self.assertRaises(ValueError): fix.check_devices(old)
                    self.assertIn('ven_ddram_axi_posted #', new)
                else:
                    fix.check_devices(old)
                    self.assertNotIn('ven_ddram_axi_posted #', new)
                # No other active RTL tokens change in either DDR profile.
                self.assertEqual(without_devices(old), without_devices(new))
                for marker in ('ven_ps2_mailbox u_mouse_mailbox',
                               'ven_ps2_device #(.CLK_HZ(CLK_HZ)) u_ps2_mouse_device'):
                    with self.assertRaises(ValueError): fix.check_devices(new.replace(marker, 'MISSING'))
                    with self.assertRaises(ValueError): fix.check_devices(new+'\n'+marker)


if __name__ == '__main__':
    unittest.main()
