"""The exact native lifetime remains unchanged after identity translation."""
import unittest

import run_system_read_ack_timing_sequence as sequence


class SequenceTests(unittest.TestCase):
    def test_identity_only(self):
        invocation='1234567890abcdef1234567890abcdef'
        old=sequence.previous.derive(invocation)
        new=sequence.derive(invocation)
        expected=old.replace('raw-prime-storage-','system-read-ack-')
        expected=expected.replace(sequence.previous.evidence.MANIFEST,sequence.evidence.MANIFEST)
        expected=expected.replace(sequence.previous.evidence.MODEL,sequence.evidence.MODEL)
        self.assertEqual(new,expected)
        self.assertIn("SYNTH_INVOCATION = '"+invocation+"'",new)
        self.assertIn('system-read-ack-timing-prepared-r1.json',new)

    def test_rejects_ambiguous_owner(self):
        for value in ('','123','system-read-ack',"'; import os"):
            with self.assertRaises(ValueError):sequence.derive(value)


if __name__=='__main__':unittest.main()
