import unittest
import prepare_fp_high_payload as p


class RecipeTests(unittest.TestCase):
    def source(self):
        return '\n'.join((p.REQUEST, p.VALID, p.OLD))

    def test_exact_reversible_mux_only(self):
        source = self.source()
        changed = p.transform(source)
        block = changed[changed.index('`ifdef '+p.FLAG):]
        self.assertEqual(changed.replace(block, p.OLD), source)
        self.assertEqual(changed.count(p.REQUEST), 1)
        self.assertEqual(changed.count(p.VALID), 1)
        self.assertIn(p.NEW, changed)
        self.assertIn('FP-HIGH-PAYLOAD-OWNER', changed)

    def test_missing_contract_rejected(self):
        for anchor in (p.REQUEST, p.VALID, p.OLD):
            with self.subTest(anchor=anchor), self.assertRaises(ValueError):
                p.transform(self.source().replace(anchor, ''))

    def test_ambiguous_contract_rejected(self):
        for anchor in (p.REQUEST, p.VALID, p.OLD):
            with self.subTest(anchor=anchor), self.assertRaises(ValueError):
                p.transform(self.source()+'\n'+anchor)

    def test_repeat_rejected(self):
        with self.assertRaises(ValueError):
            p.transform(p.transform(self.source()))


if __name__ == '__main__':
    unittest.main()
