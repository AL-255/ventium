"""Host-only ownership truth table and fail-closed recipe tests."""
import itertools
import unittest
import prepare_code_payload as p


class Tests(unittest.TestCase):
    def source(self):
        return '\n'.join((p.OLD, p.DECL,
            '  assign code_word_reuse = rst_n && c_req && code_access &&',
            p.SHADOW_GUARD, p.PRIMARY_GUARD,
            '                                 code_word_reuse ||',
            '  // ---- combinational lookup off the registered arrays (PRE-update) ----------'))

    def test_reversible_selector_only(self):
        old = self.source(); new = p.transform(old)
        restored = new.replace('`ifdef '+p.FLAG+'\n'+p.NEW+'\n`else\n'+p.OLD+'\n`endif', p.OLD)
        restored = restored.replace(p.DECL+'\n`ifdef '+p.FLAG+'\n'+p.SELECT+'\n'+p.CHECK+'\n`endif', p.DECL)
        restored = restored.replace('`ifdef '+p.FLAG+'\n'+p.GUARDS+'\n`endif\n\n', '')
        self.assertEqual(restored, old)
        self.assertNotIn('mc_lookup', p.SELECT.split('wire ')[1])
        self.assertNotIn('code_hit', p.SELECT.split('wire ')[1])

    def test_missing_ambiguous_repeated_refused(self):
        for anchor in (p.OLD, p.DECL, '                                 code_word_reuse ||'):
            with self.subTest(anchor=anchor):
                for text in (self.source().replace(anchor,''), self.source()+'\n'+anchor):
                    with self.assertRaises(ValueError): p.transform(text)
        with self.assertRaises(ValueError): p.transform(p.transform(self.source()))

    def test_consumed_owner_lemma(self):
        checked = missing_code = missing_primary = 0
        # Bypass, early and stream are higher-priority/overriding owners.
        # A data reuse owner requires !code_access. Code reuse requires code.
        # For duplicate primary/code owners a sequential byte-equality check
        # is still needed; this truth table explicitly does not prove that.
        for code, primary, code_reuse, data_reuse in itertools.product((False,True), repeat=4):
            if (code_reuse and not code) or (data_reuse and code): continue
            ack = primary or code_reuse or data_reuse
            if not ack: continue
            selected = code and not primary
            if selected: self.assertTrue(code_reuse)
            if code_reuse and not selected: self.assertTrue(primary)
            checked += 1
            missing_code += (not primary) and not code_reuse
            missing_primary += code and primary and not code_reuse
        self.assertGreater(checked,0)
        self.assertGreater(missing_code,0)
        self.assertGreater(missing_primary,0)


if __name__ == '__main__': unittest.main()
