"""The adapter changes identity, not canonical options or comparison policy."""
import unittest
import run_way_banked_checks as adapter
import run_way_banked_same_input as replay
import audit_way_banked_checks as audit


class Checks(unittest.TestCase):
    def test_preserves_gate_options(self):
        generated=adapter.derive()
        original=adapter.SOURCE.read_text()
        tail='    if a.mode==\'canonical\':'
        self.assertEqual(generated[generated.index(tail):],original[original.index(tail):])
        self.assertIn("started['changes']==CHANGES",generated)
        self.assertIn("assert changed_sources(parent/'candidate')==",generated)
        self.assertNotIn('recipe.FILE',generated)

    def test_replay_only_changes_identity_and_adds_source_pin(self):
        generated=replay.derive()
        for before,after in reversed(replay.REPLACEMENTS):
            self.assertEqual(generated.count(after),1)
            generated=generated.replace(after,before)
        pin='\n    pins['+repr(str(replay.SOURCE.resolve()))+']='+repr(replay.SOURCE_SHA)
        self.assertEqual(generated.count(pin),1)
        self.assertEqual(generated.replace(pin,''),replay.SOURCE.read_text())

    def test_audit_retains_complete_records_and_failures(self):
        generated=audit.derive()
        self.assertIn("core,func,parent=root/'way-banked-core-r1',root/'way-banked-func-r1',root/'fp-compare-core-r1'",generated)
        for line in (
            "assert r.records==tracefmt.read_trace(str(old_trace)).records==tracefmt.read_trace(str(new_trace)).records",
            "assert set(unmasked_failures)=={'tx_regform','tx_regform2','tx_stack'}",
            "assert vc['canonical_gate_passed']==(vc['canonical_gate_native_exit']==0)",
            'assert records==80800 and paired==30132 and parent_paired==30132',
            'assert not pair_deltas'):
            self.assertIn(line,generated)


if __name__=='__main__':
    unittest.main()
