import unittest
from audit_prebuilt_x87_stack import fault_deliveries, witness

LOG = '''tb: [FAULT] vec=0x10 cs=0008 eip=000f0100 fault_pc=000f0100
tb: [VEN_DBG] FSM=0x08 mode=PE vec=0xe5
[fault-deliveries] actual=1
[FAULT] vec=16 err=00000000 pc=000f0100 state=2 v86=0 depth=0
tb: FLT vec=16 fault_pc=000f0100 cs=0008 err=00000000 cr2=00000000
'''


class Audit(unittest.TestCase):
    def test_observers_not_double_counted(self):
        self.assertEqual(fault_deliveries(LOG, 1), [(16, 0xf0100, 0)])

    def test_missing_observer_rejected(self):
        with self.assertRaises(AssertionError):
            fault_deliveries(LOG.replace('tb: FLT ', 'ignored '), 1)

    def test_foreign_vector_rejected(self):
        with self.assertRaises(AssertionError):
            fault_deliveries(LOG.replace('vec=16', 'vec=13'), 1)

    def test_duplicate_delivery_rejected(self):
        with self.assertRaises(AssertionError):
            fault_deliveries(LOG + '[FAULT] vec=16 err=00000000 pc=000f0100\n', 1)

    def test_observer_pc_mismatch_rejected(self):
        with self.assertRaises(AssertionError):
            fault_deliveries(LOG.replace('fault_pc=000f0100 cs=', 'fault_pc=000f0200 cs='), 1)

    def test_wrong_error_code_rejected(self):
        with self.assertRaises(AssertionError):
            fault_deliveries(LOG.replace('err=00000000', 'err=00000001'), 1)

    def test_suppressed_bcd_case_required(self):
        last = dict(edi='0x42', ebx='0xa', ecx='0x15', edx='0x600d00f4')
        witness(last, 10, 21)
        with self.assertRaises(AssertionError):
            witness(dict(last, ecx='0x14'), 10, 21)

    def test_pass_code_alone_insufficient(self):
        last = dict(edi='0x42', ebx='0xa', ecx='0x15', edx='0')
        with self.assertRaises(AssertionError):
            witness(last, 10, 21)


if __name__ == '__main__':
    unittest.main()
