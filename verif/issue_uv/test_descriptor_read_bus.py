"""Mutation-test the independent physical-byte oracle, not just final registers."""
import copy
import unittest

from observe_descriptor_read_bus import check_bytes


def rows():
    base = dict(clk=1, __VnbaTriggered=1, state=31, q_ea=0x2ff8, q_sysop=1,
                bd_we=0, fx_act=0, m_axi_arlen=0, bypass=1,
                m_axi_arvalid=0, m_axi_arready=0, mem_ack=0)
    result = []
    for step, size in ((0, 4), (1, 2)):
        fields = dict(base, seg_step=step, cur_lin_nat=0x2ff8+4*step,
                      cur_size=size, bd_wstrb=(1 << size)-1, fbase=0x2ff8+4*step)
        if step == 0:
            result.append(dict(fields, event='start'))
        result.append(dict(fields, event='transfer', m_axi_arvalid=1, m_axi_arready=1,
                           m_axi_araddr=0x2ff8+4*step, m_axi_arsize=2-step))
        result.append(dict(fields, event='done' if step else 'transfer', mem_ack=1))
    return result


class PhysicalBytes(unittest.TestCase):
    def test_six_bytes_and_both_instructions(self):
        for op in (1, 2):
            sample = rows()
            for row in sample:
                row['q_sysop'] = op
            self.assertEqual(sum(r['bytes'] for r in check_bytes(sample)), 6)

    def test_reject_excess_missing_duplicate_and_non_handshake(self):
        original = rows()
        for kind in ('wide', 'missing', 'duplicate', 'not-ready', 'wrong-address', 'wrong-edge'):
            sample = copy.deepcopy(original)
            if kind == 'wide': sample[3]['m_axi_arsize'] = 2
            if kind == 'missing': del sample[3]
            if kind == 'duplicate': sample.insert(4, copy.deepcopy(sample[3]))
            if kind == 'not-ready': sample[3]['m_axi_arready'] = 0
            if kind == 'wrong-address': sample[3]['m_axi_araddr'] += 2
            if kind == 'wrong-edge': sample[3]['__VnbaTriggered'] = 0
            with self.subTest(kind=kind), self.assertRaises(AssertionError):
                check_bytes(sample)

    def test_diagnostic_is_not_byte_exact(self):
        sample = rows()
        for row in sample:
            row['bd_wstrb'] = 0
            row['cur_size'] = 4
        sample[3]['m_axi_arsize'] = 2
        self.assertEqual(sum(r['bytes'] for r in check_bytes(sample, overread=True)), 8)
        with self.assertRaises(AssertionError):
            check_bytes(sample)


if __name__ == '__main__':
    unittest.main()
