"""Host checks for the generated cold exception-delivery fixture."""
import unittest
import run_underflow_delivery as probe


class Delivery(unittest.TestCase):
    def test_vectors(self):
        rows = probe.vectors()
        self.assertEqual(len(rows), 8)
        self.assertEqual(rows[0]['values'], [(0x5fc2, 1 << 63)])
        self.assertEqual(rows[4]['values'], [(0xdfc2, 1 << 63)])
        for row in rows:
            self.assertIn(row['status'], (0x8090, 0x8092))
            self.assertTrue(row['values'])
            for exponent, mantissa in row['values']:
                self.assertTrue(0x5fc2 <= exponent & 0x7fff < 0x6001)
                self.assertTrue(mantissa & (1 << 63))

    def test_waiter_and_retries(self):
        for row in probe.vectors():
            for waiter in ('fwait', 'fnop', 'fld1'):
                source = probe.source(row, waiter)
                arm = source.split('.macro ARM_PENDING_MF\n')[1].split('.endm')[0]
                self.assertEqual(arm.splitlines()[-1].strip(), 'fprem1' if row['op'] else 'fprem')
                self.assertNotIn('fnstsw', arm)
                self.assertNotIn('fwait', arm)
                self.assertEqual(source.count('    CHECK_REMAINDER\n'), 2)
                self.assertIn(f'andl    $0x80ff, %eax', source)
                self.assertIn(f'cmpl    $0x{row["status"]:04x}, %eax', source)
                self.assertEqual(source.count('\n    '+waiter+'\n'), 4 if waiter == 'fld1' else 2)


if __name__ == '__main__':
    unittest.main()
