import unittest
from audit_endpoint_map_doom import observations


class StallObservation(unittest.TestCase):
    def test_success_is_never_inferred(self):
        row=observations('exit 0\nDOOM_DEMO3_RETURNED\n')
        self.assertFalse(row['guest_accepted'])
        self.assertIsNone(row['fps'])
        self.assertIsNone(row['gameplay_ipc'])

    def test_stalled_native_exit(self):
        text='\n'.join([
            '[VEN-PERF] cycle=34 retires=9 clocks=34 u=9 v=0',
            '[VEN-PERF] cycle=100 retires=9 clocks=100 u=9 v=0',
            '[STALL] no retire for 65 cyc: state=40 cs=16f0:eip=0000daf0',
            '>>> done: cyc=100 retires=9 last cs=16f0:eip=0000daf0'])
        row=observations(text)
        self.assertEqual(row['longest_no_retire_cycles'],65)
        self.assertEqual(row['sampled_no_retire_window'],[34,100])
        self.assertEqual(row['last_stall']['state'],40)
        self.assertEqual(row['final_cs'],'16f0')
        self.assertFalse(row['guest_accepted'])


if __name__=='__main__':unittest.main()
