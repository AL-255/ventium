"""Host-only exact-transform and owner-lemma tests; not sequential RTL proof."""
import itertools
import unittest
import prepare_high_window_payload as p


class RecipeTests(unittest.TestCase):
    def source(self):
        return '\n'.join((p.OLD, p.VALID, p.REUSE))

    def test_only_payload_mux_changes(self):
        old = self.source()
        new = p.transform(old)
        block = '\n'.join(('`ifdef '+p.FLAG, p.GUARDS, p.SELECT, p.NEW,
                            p.CHECKS, '`else', p.OLD, '`endif'))
        self.assertEqual(new.replace(block, p.OLD), old)
        self.assertEqual(new.count(p.VALID), 1)
        self.assertEqual(new.count(p.REUSE), 1)
        self.assertNotIn('rd_match', p.SELECT.split('wire ')[1])
        self.assertIn('!code_access', p.SELECT)

    def test_missing_or_duplicate_contract(self):
        for anchor in (p.OLD, p.VALID, p.REUSE):
            with self.subTest(anchor=anchor):
                for bad in (self.source().replace(anchor, ''), self.source()+'\n'+anchor):
                    with self.assertRaises(ValueError):
                        p.transform(bad)

    def test_repeated_transform_refused(self):
        with self.assertRaises(ValueError):
            p.transform(p.transform(self.source()))

    def test_owner_lemma_and_required_negatives(self):
        # Common = all request/permission/coherence qualifiers shared by high
        # VALID and shadow_reuse. Offset is checked explicitly, not assumed.
        valid_cases = low_selector_failures = missing_identity_failures = code_failures = 0
        for common, shadow_valid, same_shadow, code, full, match, reuse, same_primary in itertools.product((False, True), repeat=8):
            for offset in range(32):
                old = common and shadow_valid and same_shadow and not code and offset <= 28
                valid = common and offset <= 24 and ((full and (match or reuse) and same_primary) or old)
                new = shadow_valid and same_shadow and not code
                if valid:
                    valid_cases += 1
                    self.assertEqual(new, old)
                    low_selector_failures += (new and not match) != old
                    missing_identity_failures += (shadow_valid and not code) != old
                    code_failures += (shadow_valid and same_shadow) != old
        self.assertGreater(valid_cases, 0)
        for count in (low_selector_failures, missing_identity_failures, code_failures):
            self.assertGreater(count, 0)


if __name__ == '__main__':
    unittest.main()
