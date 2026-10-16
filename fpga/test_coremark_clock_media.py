import unittest
import prepare_coremark_clock_media as media


class ClockMedia(unittest.TestCase):
    def sample(self):
        return ('CoreMark Size    : 666\nIterations      : 2000\nseedcrc : 0xe9f5\n'
                '[0]crclist : 0xe714\n[0]crcmatrix : 0x1fd7\n[0]crcstate : 0x8e3a\n'
                '[0]crcfinal : 0x1234\nCorrect operation validated.\nPORT-END\n')

    def test_reference_is_never_board_or_timing_acceptance(self):
        result=media.grade_reference(self.sample(),'performance')
        self.assertEqual(result['crcs'][-1],'1234')
        self.assertFalse(result['physical_board'])
        self.assertTrue(result['qemu_time_is_not_fpga_time'])

    def test_incomplete_duplicate_wrong_seed_and_algorithm_errors(self):
        for text in (self.sample().replace('PORT-END\n',''),
                     self.sample()+'PORT-END\n',self.sample()+'seedcrc : 0xe9f5\n',
                     self.sample().replace('0xe714','0x0000'),
                     self.sample().replace('2000','10'),
                     self.sample()+'ERROR! bad CRC\n'):
            with self.assertRaises(ValueError): media.grade_reference(text,'performance')

    def test_only_known_qemu_timer_errors_can_be_retained(self):
        text=self.sample().replace('Correct operation validated.',
            'ERROR! Must execute for at least 10 secs for a valid result!\nErrors detected')
        self.assertTrue(media.grade_reference(text,'performance')['timing_errors'])
        with self.assertRaises(ValueError):
            media.grade_reference(text+'ERROR! unknown clock error\n','performance')


if __name__=='__main__': unittest.main()
