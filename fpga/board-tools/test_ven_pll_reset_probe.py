import unittest
from unittest.mock import patch

import ven_pll_reset_probe as probe


class Box:
    def __init__(self, values):
        self.values = iter(values)
        self.requests = []

    def read(self):
        return next(self.values)

    def request(self, lines, flags):
        self.requests.append((lines, flags))
        return 77


class ResetProbe(unittest.TestCase):
    def run_probe(self, box, writes):
        return probe.probe_reset(box, set_values=lambda fd, data: writes.append((fd, data)),
                                 sleep=lambda _: None)

    def test_ready_and_persistent_failure(self):
        for final, ready in ((0x504c5499, True), (0x504c6219, False)):
            box, writes = Box([0x504c6219, 0x504c6119, final]), []
            with self.subTest(ready=ready), patch.object(probe.os, 'close') as close:
                result = self.run_probe(box, writes)
                self.assertEqual(result['clock_ready'], ready)
                self.assertEqual(box.requests, [((173,), 2)])
                self.assertEqual(writes, [(77, bytearray([1]+[0]*63))])
                close.assert_called_once_with(77)

    def test_refuse_running_clock_before_claim(self):
        box = Box([0x504c5499])
        with self.assertRaises(ValueError):
            self.run_probe(box, [])
        self.assertEqual(box.requests, [])

    def test_failed_reset_witness_still_releases(self):
        box, writes = Box([0x504c6219, 0x504c6219]), []
        with patch.object(probe.os, 'close') as close, self.assertRaises(ValueError):
            self.run_probe(box, writes)
        self.assertEqual(writes, [(77, bytearray([1]+[0]*63))])
        close.assert_called_once_with(77)

    def test_capture_reset_released_before_lock_timeout(self):
        box, writes = Box([0x504c6219, 0x504c6119, 0x504c4119, 0x504c6219]), []
        with patch.object(probe.os, 'close'):
            result = self.run_probe(box, writes)
        self.assertFalse(result['clock_ready'])
        self.assertFalse(result['transitions'][0]['status']['mmcm_reset'])
        self.assertTrue(result['transitions'][1]['status']['mmcm_reset'])


if __name__ == '__main__':
    unittest.main()
