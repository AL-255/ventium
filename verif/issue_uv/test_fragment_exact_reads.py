"""Source scope checks for the fragment byte-exactness correction."""
import os
from pathlib import Path
import unittest

import prepare_fragment_exact_reads as exact
import prepare_fragment_read_payload as payload


class ExactReadRecipe(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ['FRAGMENT_PAYLOAD_PARENT'])
        self.core = (root/'core.sv').read_text()
        self.bus = (root/'core_bus_driver.svh').read_text()

    def test_only_decl_capture_and_mask_plus_payload_cofactor(self):
        changed = exact.transform(self.core, self.bus)
        for before, after in reversed(exact.EDITS):
            self.assertEqual(changed.count(after), 1)
            changed = changed.replace(after, before)
        self.assertEqual(changed.replace(payload.NEW, payload.OLD), self.core)

    def test_request_and_start_equations_unchanged(self):
        changed = exact.transform(self.core, self.bus)
        self.assertEqual(payload.blocks(self.core)[0], payload.blocks(changed)[0])
        self.assertIn('fx_wstrb_q <= bd_we ? bd_wstrb : fx_read_strb;', changed)
        for signal in ('mem_req', 'mem_ack', 'fx_hold_e', 'fx_wrsup_e'):
            def assignment(text):
                start = text.index('  assign '+signal+' ')
                return text[start:text.index(';', start)+1]
            self.assertEqual(assignment(self.core), assignment(changed))

    def test_exact_sequencer_in_leaf(self):
        changed = exact.transform(self.core, self.bus)
        leaf = exact.engine(changed)
        self.assertIn(exact.between(changed, exact.SEQ_START, exact.SEQ_END), leaf)
        self.assertNotIn('logic        fx_abort_q;', leaf)
        self.assertIn('else if (state == S_WALK)', leaf)

    def test_drift_rejected(self):
        for core, bus in ((self.core+'\n', self.bus), (self.core, self.bus+'\n')):
            with self.assertRaises(ValueError):
                exact.transform(core, bus)
        with self.assertRaises(ValueError):
            exact.engine(self.core+self.core)


if __name__ == '__main__':
    unittest.main()
