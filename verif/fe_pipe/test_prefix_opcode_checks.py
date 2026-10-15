from pathlib import Path
import unittest

import run_prefix_opcode_checks as binding
import audit_prefix_opcode_checks as audit


class CheckBindings(unittest.TestCase):
    def test_audit_only_rebinds_identities(self):
        text=audit.derive()
        source=Path(audit.previous.__file__).resolve()
        pin=repr(str(source))+':'+repr(audit.SOURCE_SHA)+','
        self.assertEqual(text.count(pin),1)
        text=text.replace(pin,'')
        for before,after,count in reversed(audit.REPLACEMENTS):
            self.assertEqual(text.count(after),count)
            text=text.replace(after,before)
        self.assertEqual(text,audit.previous.derive())

    def test_exact_reversal_all_adapters(self):
        for mode,(name,_) in binding.SOURCES.items():
            with self.subTest(mode=mode):
                text,replacements=binding.derive(mode)
                for before,after in reversed(replacements):
                    self.assertEqual(text.count(after),1,after)
                    text=text.replace(after,before)
                self.assertEqual(text,(binding.REPO/name).read_text())

    def test_comparison_and_fixture_policy_unchanged(self):
        for mode,marker in (('checks',"    if a.mode=='canonical':"),
                            ('replay','    golden_by_name = {}'),
                            ('system',"    specs=[('psysfpbounded'")):
            text,_=binding.derive(mode)
            old=(binding.REPO/binding.SOURCES[mode][0]).read_text()
            self.assertEqual(text[text.index(marker):],old[old.index(marker):])


if __name__=='__main__': unittest.main()
