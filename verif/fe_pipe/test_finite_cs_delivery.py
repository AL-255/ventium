import copy
from types import SimpleNamespace
import unittest

import audit_finite_cs_rtl as audit


class DeliveryContract(unittest.TestCase):
    def setUp(self):
        state = {k: '0x00000000' for k in audit.original.tracefmt.func_compare_keys(False, True)}
        state.update(pc='0xf0287', cs='0x0028', esp='0x8fff0', eax='0x12348001',
                     ebx='0x11112222', eflags='0x00000086')
        delivery = dict(state, pc='0x2fffd', cs='0x0018', esp='0x8ffe0')
        self.trace = SimpleNamespace(mode='func', records=[state, delivery, dict(delivery, pc='0xf030c')])

    def test_delivery_not_add_commit(self):
        self.assertEqual(audit.check_delivery(self.trace, 0x2fffd), 1)
        self.assertTrue(callable(audit.checked_grade()))

    def test_commit_frame_and_control_corruption_rejected(self):
        for key, value in (('eax', '0x12349235'), ('ebx', '0x456789ab'), ('ecx', '0x1'),
                           ('cs', '0x28'), ('esp', '0x8ffe4'), ('eflags', '0x46'), ('cr3', '0x11000')):
            trace = copy.deepcopy(self.trace); trace.records[1][key] = value
            with self.subTest(key=key), self.assertRaises(AssertionError):
                audit.check_delivery(trace, 0x2fffd)

    def test_missing_duplicate_or_paired_delivery_rejected(self):
        for records in (self.trace.records[:1]+self.trace.records[2:],
                        self.trace.records[:2]+self.trace.records[1:]):
            with self.assertRaises(AssertionError):
                audit.check_delivery(SimpleNamespace(mode='func', records=records), 0x2fffd)
        for pipe, paired in (('V', False), ('U', True)):
            trace = copy.deepcopy(self.trace); trace.mode = 'cycle'
            trace.records[1].update(pipe=pipe, paired=paired)
            with self.assertRaises(AssertionError):
                audit.check_delivery(trace, 0x2fffd)

    def test_both_witness_instructions_require_real_partners(self):
        trace = SimpleNamespace(records=[
            dict(pc='0xf02af', pipe='U', paired=False, cyc=10),
            dict(pc='0xf02b0', pipe='V', paired=True, cyc=10),
            dict(pc='0xf02b5', pipe='U', paired=False, cyc=11),
            dict(pc='0xf02ba', pipe='V', paired=True, cyc=11)])
        audit.check_witness_pairing(trace, 0xf02b5)
        for index, patch in ((0, dict(pipe='V')), (1, dict(paired=False)),
                             (1, dict(cyc=12)), (3, dict(paired=False)), (3, dict(pipe='U'))):
            changed = copy.deepcopy(trace); changed.records[index].update(patch)
            with self.subTest(index=index, patch=patch), self.assertRaises(AssertionError):
                audit.check_witness_pairing(changed, 0xf02b5)


if __name__ == '__main__':
    unittest.main()
