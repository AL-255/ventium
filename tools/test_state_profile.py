import unittest

from state_profile import records, render, summarize


def line(cyc, n, state=1, pc=0x10, ack=0, rsp=0):
    return (f'VENSTATE cyc={cyc} n={n} state={state} eip={pc:08x} '
            f'fx=6 step=0 ack={ack} addr=00001000 we=0 rsp={rsp}\n')


class StateProfileTest(unittest.TestCase):
    def test_pair_and_endpoint_accounting(self):
        result = summarize([line(10, 100), line(11, 100, ack=1),
                            line(12, 102, state=2, pc=0x12)])
        self.assertEqual(sum(result['states'].values()), 3)
        self.assertEqual(result['signals']['ack_high'], 1)
        self.assertIn('2 retirements / 2 cycles', render(result))
        self.assertIn('IPC: 1.000000', render(result))

    def test_pc_filter_does_not_redefine_ipc(self):
        result = summarize([line(10, 100), line(11, 101, pc=0x20)], pc=0x10)
        self.assertEqual(sum(result['states'].values()), 1)
        self.assertEqual(result['pcs'], {0x10: 1})
        self.assertIn('1 retirements / 1 cycles', render(result))

    def test_reject_discontinuity_and_reset(self):
        for second in (line(12, 100), line(10, 100), line(11, 99)):
            with self.subTest(second=second), self.assertRaises(ValueError):
                summarize([line(10, 100), second])

    def test_malformed_and_absent(self):
        for rows in (['ordinary log\n'], ['VENSTATE cyc=1\n'],
                     [line(1, 1).replace('ack=0', 'ack=2')]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                summarize(rows)

    def test_optional_response_single_sample_and_empty_selection(self):
        result = summarize(['noise\n', 'prefix ' + line(1, 2, rsp=-1)])
        self.assertEqual(result['signals']['rsp_unavailable'], 1)
        self.assertIn('undefined', render(result))
        result = summarize([line(1, 2)], pc=0x1234)
        self.assertEqual(sum(result['states'].values()), 0)
        self.assertIn('observations: 0', render(result))
        self.assertEqual(len(list(records([line(1, 2)]))), 1)


if __name__ == '__main__':
    unittest.main()
