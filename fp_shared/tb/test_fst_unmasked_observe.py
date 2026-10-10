"""Host tests for the finite unmasked-store witness; not RTL verification."""
import unittest
import run_fst_unmasked_observe as o


class Tests(unittest.TestCase):
    def pick(self, **values):
        return next(c for c in o.cases() if all(c[k] == v for k,v in values.items()))

    def test_matrix(self):
        cases = o.cases()
        self.assertEqual(len(cases), 1920)
        self.assertEqual(len({tuple(c.values()) for c in cases}), 1920)
        self.assertEqual({c['mask'] for c in cases}, {0x3f, 0x37, 0x2f, 0x1f, 7})

    def test_exact_tiny_requires_unmasked_exception(self):
        c = self.pick(kind='tiny-exact', mask=0x2f, pop=1)
        want = o.expected(c)
        self.assertTrue(want['blocked'])
        self.assertFalse(want['popped'])
        self.assertEqual(want['flags'], 0x10)
        self.assertEqual(want['st0'], o.masked.input80(c))
        self.assertFalse(o.expected(dict(c, mask=0x3f))['blocked'])

    def test_unmasked_precision_delivers_result_and_pop(self):
        c = self.pick(kind='normal-inexact', mask=0x1f, pop=1)
        want = o.expected(c)
        self.assertFalse(want['blocked'])
        self.assertTrue(want['popped'])
        self.assertEqual(want['flags'], 0x20)
        self.assertEqual(want['sw'] & 0x8080, 0x8080)

    def test_tiny_round_to_normal_is_not_unmasked_underflow(self):
        c = self.pick(kind='tiny-round-normal', mask=0x2f, rc=0, pop=1)
        self.assertFalse(o.expected(c)['blocked'])
        self.assertEqual(o.expected(c)['flags'], 0x20)

    def test_overflow_preserves_memory_and_stack(self):
        c = self.pick(kind='overflow-exact', mask=0x37, bits=32, pop=1)
        want = o.expected(c)
        self.assertEqual(want['value'], 0xa5a5a5a5)
        self.assertEqual(want['tw'], 0x3fff)
        self.assertEqual(want['flags'], 8)

    def test_real_control_words_and_no_wait_save(self):
        items = o.cases()[:3]
        asm = o.assembly(items)
        self.assertEqual(asm.count('fldcw unmasked_cw_'), 3)
        self.assertEqual(asm.count('fnsave rows+'), 3)
        self.assertNotIn('fwait', asm)
        for c in items:
            self.assertEqual(o.control(c) & 0x340, 0x340)

    def test_all_defined_state_fields_checked(self):
        want = o.expected(self.pick(kind='tiny-exact', mask=0x2f))
        observed = {k:v for k,v in want.items() if k not in ('blocked', 'popped')}
        self.assertEqual(o.differences(observed, want), [])
        for key in observed:
            with self.subTest(key=key):
                changed = dict(observed); changed[key] ^= 1
                self.assertEqual(o.differences(changed, want), [key])


if __name__ == '__main__':
    unittest.main()
