import unittest
from ven_uv_fast_guard import paired_fast_witness, require_running


class ModeGuardTests(unittest.TestCase):
    def witness(self, rows):
        return paired_fast_witness(rows, cs=0xa7, u_pc=0x14562,
                                   successor_pcs={0x14567, 0x1457a})

    def ring(self, pcs, state=28, cs=0xa7):
        return '\n'.join(f'[{n:3}] cs={cs:04x} eip={pc:08x} state={state} lin=ffffffff'
                         for n, pc in enumerate(pcs))

    def test_running(self):
        require_running(0, 0)
        require_running(0x200, 0)

    def test_suppression_rejected(self):
        for bit in (1, 2, 4, 0x100):
            with self.subTest(bit=bit), self.assertRaises(ValueError):
                require_running(bit, 0)
        with self.assertRaises(ValueError):
            require_running(0, 0x80000000)

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
