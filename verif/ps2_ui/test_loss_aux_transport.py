"""The diagnostic TB change must not alter any transport assertion/stimulus."""
from pathlib import Path
import unittest

from run_loss_aux_transport import BASE, TB_SHA, bounded_tb, sha


class TransportBound(unittest.TestCase):
    def test_only_deadline_and_read_only_latency_log_change(self):
        path = BASE/'source/tb_ps2_device.sv'
        self.assertEqual(sha(path), TB_SHA)
        before = path.read_text()
        after = bounded_tb(before)
        log = ('            $display("PS2-RECEIVE-LATENCY hz=%0d byte=%02x clocks=%0d limit=%0d",'
               'HZ,expected,n,2*8192+CELL*12+256);\n')
        self.assertEqual(after.count(log), 1)
        self.assertEqual(after.replace(log, '').replace(
            'n < 2*8192+CELL*12+256', 'n < 15000+CELL*12'), before)
        self.assertEqual(after.count('$fatal'), before.count('$fatal'))

    def test_source_drift_and_reapplication_rejected(self):
        before = (BASE/'source/tb_ps2_device.sv').read_text()
        for changed in (before+'\n', before.replace('15000+CELL*12', '999999'), bounded_tb(before)):
            with self.subTest(source_length=len(changed)), self.assertRaises(ValueError):
                bounded_tb(changed)


if __name__ == '__main__': unittest.main()
