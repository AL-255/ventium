import unittest
from ven_uv_fast_guard import paired_fast_witness, require_running


class ModeGuardTests(unittest.TestCase):
    def witness(self, rows):
        return paired_fast_witness(rows, cs=0xa7, u_pc=0x14562,
                                   successor_pcs={0x14567, 0x1457a}, pipe_state=28)

    def ring(self, pcs, state=28, cs=0xa7):
        return '\n'.join(f'[{n:3}] cs={cs:04x} eip={pc:08x} state={state} lin=ffffffff'
                         for n, pc in enumerate(pcs))

    def test_running(self):
        self.assertEqual(require_running(0, 0, capability=0x56450005),
                         dict(running_observed=True, step_history_observable=False,
                              uv_fast_qualified=False))

    def test_unknown_abi_and_missing_capability_rejected(self):
        for cap in (0, 0xffffffff, 0x56450004, 0x56450009):
            with self.subTest(cap=cap), self.assertRaises(ValueError):
                require_running(0, 0, capability=cap)
        with self.assertRaises(TypeError):
            require_running(0, 0)

    def test_command_words_are_not_abi5_readback(self):
        for word in (8, 0x100, 0x200, 0x80000000, -1, 0x100000000, 0.0, False):
            with self.subTest(word=word), self.assertRaises(ValueError):
                require_running(word, 0, capability=0x56450005)
        for word in (-1, 0x100000000, 0.0, False):
            with self.subTest(freeze=word), self.assertRaises(ValueError):
                require_running(0, word, capability=0x56450005)

    def test_pipe_enum_must_be_explicit(self):
        with self.assertRaises(TypeError):
            paired_fast_witness(self.ring([0x14567, 0x14562]), cs=0xa7,
                                u_pc=0x14562, successor_pcs={0x14567})

    def test_suppression_rejected(self):
        for bit in (1, 2, 4):
            with self.subTest(bit=bit), self.assertRaises(ValueError):
                require_running(bit, 0, capability=0x56450005)
        with self.assertRaises(ValueError):
            require_running(0, 0x80000000, capability=0x56450005)

    def test_paired_taken_and_not_taken(self):
        for pc in (0x14567, 0x1457a):
            self.assertEqual(self.witness(self.ring([pc, 0x14562]))['state'], 28)

    def test_unpaired_not_accepted(self):
        with self.assertRaises(ValueError):
            self.witness(self.ring([0x14567, 0x14565, 0x14562]))

    def test_wrong_target_not_accepted(self):
        with self.assertRaises(ValueError):
            self.witness(self.ring([0x14566, 0x14562]))

    def test_slow_or_wrong_selector_not_accepted(self):
        for options in ({'state': 2}, {'cs': 8}):
            with self.assertRaises(ValueError):
                self.witness(self.ring([0x14567, 0x14562], **options))

    def test_empty_and_broken_ring(self):
        for ring in ('', '[bad]', self.ring([0x14567, 0x14562]).replace('[  1]', '[  2]')):
            with self.assertRaises(ValueError):
                self.witness(ring)


if __name__ == '__main__':
    unittest.main()
