import unittest
from run_hosted_keyboard_transport import ROOT,grade,keyboard_tb


class KeyboardTransportTests(unittest.TestCase):
    def test_exact_adapter(self):
        source=(ROOT/'ps2-loss-aux-transport-r1/source/tb_ps2_device.sv').read_text()
        text=keyboard_tb(source)
        self.assertEqual(text.count('$fatal'),source.count('$fatal'))
        self.assertNotIn("io_wr(4,8'hd4)",text)
        self.assertEqual(text.count("io_wr(0,8'h03)"),2)
        self.assertIn('.ps2_kbclk_out(hc)',text)
        self.assertIn('.irq_keyb(irq_mouse),.irq_mouse(irq_keyb)',text)
        self.assertIn("(status & 8'ha1) !== 8'h01",text)
        self.assertIn('n < 2*8192+CELL*12+256',text)
        for changed in (source+'\n',text):
            with self.assertRaises(ValueError): keyboard_tb(changed)

    def test_grade_requires_all_profiles_and_latencies(self):
        text='\n'.join('PS2-RECEIVE-LATENCY hz=40000000 byte=ff clocks=12 limit=100' for _ in range(36))
        text+='\nPS2-DEVICE-OK hz=3125000 checks=49 completed=26 aborted=2'
        text+='\nPS2-DEVICE-OK hz=40000000 checks=49 completed=26 aborted=2\nPS2-DEVICE-ALL-OK profiles=2'
        self.assertTrue(grade(0,text))
        for bad in (text.replace('checks=49','checks=48'),text.replace('limit=100','limit=1'),
                    text+'\nPS2-DEVICE-ALL-OK profiles=2',text+' FATAL'):
            self.assertFalse(grade(0,bad))
        self.assertFalse(grade(1,text))


if __name__=='__main__': unittest.main()
