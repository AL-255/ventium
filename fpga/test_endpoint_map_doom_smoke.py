"""Keep diagnostic observations distinct from a successful guest timedemo."""
import unittest
from run_endpoint_map_doom_smoke import summary


class Observation(unittest.TestCase):
    def test_empty_window_is_not_a_boot_or_game_pass(self):
        observed=summary('native exit 0\n')
        self.assertTrue(all(not value for value in observed.values()))
        self.assertNotIn('passed',observed)
        self.assertNotIn('fps',observed)

    def test_return_marker_does_not_hide_fault(self):
        observed=summary('[BOOT] reached boot sector 0000:7c00\n'
            '  |DOOM_DEMO3_START\n  |Invalid Opcode at 244C:6263\n  |DOOM_DEMO3_RETURNED\n')
        self.assertTrue(observed['boot_sector_observed'])
        self.assertTrue(observed['dos_marker_observed'])
        self.assertTrue(observed['returned_marker_observed'])
        self.assertTrue(observed['invalid_opcode_observed'])
        self.assertFalse(observed['native_error_observed'])

    def test_echoed_command_and_graphics_are_not_completion(self):
        observed=summary('  |C:\\>ECHO DOOM_DEMO3_START\n[FBCAP] frame_00001.ppm\n')
        self.assertFalse(observed['dos_marker_observed'])
        self.assertFalse(observed['returned_marker_observed'])
        self.assertEqual(observed['graphics_captures'],1)
        self.assertNotIn('passed',observed)

    def test_native_error_stays_visible(self):
        for text in ('%Error: assertion','%Fatal: failure','CPU HUNG','UNIMPLEMENTED opcode'):
            self.assertTrue(summary(text)['native_error_observed'])


if __name__=='__main__':unittest.main()
