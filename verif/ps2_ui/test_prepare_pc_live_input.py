import unittest

import prepare_pc_live_input as p


class Adapter(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (p.PARENT / p.MAIN).read_text()
        cls.result = p.transform(cls.source)

    def test_frozen_source_and_protocol(self):
        self.assertEqual(p.sha((p.PARENT / p.PS2).read_bytes()), p.PS2_SHA)
        self.assertEqual(p.sha((p.HERE / 'ui_input_host.h').read_bytes()), p.INPUT_SHA)
        with self.assertRaises(ValueError):
            p.transform(self.source + '\n')

    def test_no_clock_or_cpu_changes(self):
        for token in ('top->eval();', 'set_clocks(0);', 'set_clocks(1);',
                      'tick();', 'ven_debug_drive();', 'ps2_mouse_drive();'):
            self.assertEqual(self.source.count(token), self.result.count(token), token)
        pre = self.result.index('ui_edge = ven_ui::pc_keyboard_before')
        clock = self.result.index('set_clocks(1); step_vga_clock(); top->eval();')
        post = self.result.index('ven_ui::pc_keyboard_after')
        self.assertLess(pre, clock)
        self.assertLess(clock, post)
        self.assertEqual(self.result.count('g_ui->poll('), 1)

    def test_converter_pixels_unchanged(self):
        # The entire original pixel-conversion loop is retained byte-for-byte.
        original = self.source.split('    auto DAC =', 1)[1].split('    fclose(f);', 1)[0]
        self.assertIn('    auto DAC =' + original, self.result)
        self.assertIn('complete_raw_file(f, true)', self.result)
        self.assertIn('exclusive ? "wbx" : "wb"', self.result)
        self.assertIn('g_ui_captures >= 64', self.result)

    def test_cold_non_debug_options_and_clean_finish(self):
        self.assertIn('ven_ui::forbidden_ui_option(argv[i])', self.result)
        self.assertIn('!strncmp(argv[i], "--ven-break", 11)', self.result)
        self.assertIn('if (g_ui && !g_ui->finish(main_time)) stop_request_exit = 2;', self.result)
        self.assertNotIn('if (g_ui) load_state', self.result)

    def test_duplicate_anchor_fails(self):
        with self.assertRaises(ValueError):
            p.once('a a', 'a', 'b')
        with self.assertRaises(ValueError):
            p.once('a', 'b', 'c')


if __name__ == '__main__':
    unittest.main()
