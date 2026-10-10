"""Guard the exact register-store branch of the passive native witness."""
import copy
import unittest

from check_preexit_c1_native import exact_operation


class RegisterStoreWitness(unittest.TestCase):
    @staticmethod
    def witness(top=7, c1=1):
        before = (top << 11) | (c1 << 9) | 0x4520
        # Keep C0/C2/C3 and sticky PE; only TOP/C1 change in this fixture.
        before = (before & ~0x3800) | (top << 11)
        after = (before & ~0x3a00) | (((top + 1) % 8) << 11)
        return dict(instruction_prefix='ddd8ddd800000000',
                    before=dict(fstat=hex(before), fxsave_tag=hex(1 << top)),
                    after=dict(fstat=hex(after), fxsave_tag='0x00'))

    def test_every_top_and_seed(self):
        for top in range(8):
            for c1 in (0, 1):
                with self.subTest(top=top, c1=c1):
                    value = exact_operation(self.witness(top, c1))
                    self.assertEqual(value['exact_c1'], 0)
                    self.assertTrue(value['native_pop_verified'])

    def test_preserve_other_occupied_slots(self):
        value = self.witness(3)
        value['before']['fxsave_tag'] = '0xc9'
        value['after']['fxsave_tag'] = '0xc1'
        self.assertEqual(exact_operation(value)['exact_c1'], 0)

    def test_reject_empty_source_or_bad_pop(self):
        original = self.witness()
        changes = (
            ('before', 'fxsave_tag', '0x00'),
            ('after', 'fxsave_tag', '0x80'),
            ('after', 'fxsave_tag', '0x01'),
            ('after', 'fstat', hex(int(original['after']['fstat'], 16) | 0x0800)),
            ('after', 'fstat', hex(int(original['after']['fstat'], 16) ^ 0x0020)),
        )
        for side, field, value in changes:
            altered = copy.deepcopy(original)
            altered[side][field] = value
            with self.subTest(side=side, field=field, value=value), self.assertRaises(AssertionError):
                exact_operation(altered)

    def test_expected_c1_is_not_copied_from_observation(self):
        value = self.witness()
        value['after']['fstat'] = hex(int(value['after']['fstat'], 16) | 0x0200)
        self.assertEqual(exact_operation(value)['exact_c1'], 0)


if __name__ == '__main__':
    unittest.main()
