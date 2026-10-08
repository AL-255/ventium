"""Host-only capture grammar/lifecycle tests; never contacts the board."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import zlib

import ven_record_stream as recorder


def frame(seq=1, host=1, cycles=1, *, width=320, height=200, pixels=64000, crc=None):
    payload = bytes(range(256))*250
    if crc is None:
        crc = zlib.crc32(payload)&0xffffffff
    return recorder.FRAME_HEADER.pack(b'VFRM',seq,host,cycles,width,height,pixels,crc)+payload


HEADER = recorder.STREAM_HEADER.pack(b'VENVCAP1',1,recorder.MAX_FRAMES)


def feed(data, chunk=8191):
    parser = recorder.Validator()
    for offset in range(0,len(data),chunk):
        parser.feed(data[offset:offset+chunk])
    parser.finish()
    return parser


class GrammarTests(unittest.TestCase):
    def test_arbitrary_chunk_boundaries(self):
        for chunk in (1,15,16,17,35,36,37,65536):
            with self.subTest(chunk=chunk):
                parsed=feed(HEADER+frame()+frame(3,2,2),chunk)
                self.assertEqual(parsed.count,2)
                self.assertEqual(parsed.last['sequence'],3)

    def test_forward_sequence_wrap(self):
        self.assertEqual(feed(HEADER+frame(2**29-1)+frame(0,2,2)).count,2)

    def test_wrong_header(self):
        for args in ((b'VENVCAP0',1,32768),(b'VENVCAP1',2,32768),(b'VENVCAP1',1,0),(b'VENVCAP1',1,32769)):
            with self.subTest(args=args),self.assertRaises(ValueError):
                feed(recorder.STREAM_HEADER.pack(*args)+frame())

    def test_geometry_crc_and_sequence_range(self):
        for kwargs in ({'width':319},{'height':201},{'pixels':63999},{'crc':0},{'seq':2**29}):
            with self.subTest(kwargs=kwargs),self.assertRaises(ValueError):
                feed(HEADER+frame(**kwargs))

    def test_duplicate_backward_or_ambiguous_order(self):
        for fields in ((1,2,2),(0,2,2),(2**28+1,2,2),(2,1,2),(2,2,1)):
            with self.subTest(fields=fields),self.assertRaises(ValueError):
                feed(HEADER+frame()+frame(*fields))

    def test_bad_record_marker(self):
        with self.assertRaises(ValueError):
            feed(HEADER+b'NOPE'+frame()[4:])

    def test_empty_truncation_and_trailing_bytes(self):
        for raw in (b'',HEADER[:5],HEADER,HEADER+frame()[:-1],HEADER+frame()+b'x'):
            with self.subTest(size=len(raw)),self.assertRaises(ValueError):
                feed(raw)

    def test_quota_and_buffer_bound(self):
        parser=recorder.Validator();parser.feed(HEADER)
        parser.count=recorder.MAX_FRAMES
        with self.assertRaises(ValueError):parser.feed(frame())
        with self.assertRaises(ValueError):recorder.Validator().feed(b'x'*65537)


class NativeTransportTests(unittest.TestCase):
    def setUp(self):
        scratch=Path(os.environ['TMPDIR']).resolve(strict=True)
        if scratch != Path('/home/yukidama/external/tmp').resolve(strict=True):
            raise RuntimeError('use the external TMPDIR for these synthetic tests')
        self.tmp=tempfile.TemporaryDirectory(prefix='ventium-stream-test.',dir=scratch)
        self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        self.payload=HEADER+frame()+frame(2,2,2)
        self.source=self.root/'synthetic.vcap'
        self.source.write_bytes(self.payload)

    def child(self, suffix=''):
        return [sys.executable,'-B','-c',
            'import os,sys,time; sys.stdout.buffer.write(open(sys.argv[1],"rb").read()); sys.stdout.flush(); '+suffix,
            str(self.source)]

    def test_native_success_is_transport_only(self):
        result=recorder.record(self.root,self.child(),seconds=5,idle_seconds=2)
        self.assertEqual(result['result'],'PASS_CLOSED_FRAME_TRANSPORT')
        self.assertEqual(result['reader_exit'],0)
        self.assertFalse(result['acceptance'])
        self.assertFalse(result['full_timedemo'])
        self.assertIsNone(result['gameplay_ipc'])
        with gzip.open(self.root/'raw.vcap.gz','rb') as stream:
            raw=stream.read()
        self.assertEqual(raw,self.payload)
        self.assertEqual(hashlib.sha256(raw).hexdigest(),result['raw_sha256'])
        self.assertEqual(len(raw),result['raw_bytes'])
        self.assertEqual(result['raw_bytes'],result['received_bytes'])
        self.assertEqual(json.loads((self.root/'transport-closed.json').read_text()),result)

    def test_complete_bytes_with_failed_native_exit_are_not_a_pass(self):
        result=recorder.record(self.root,self.child('sys.exit(7)'),seconds=5,idle_seconds=2)
        self.assertEqual(result['reader_exit'],7)
        self.assertEqual(result['frames'],2)
        self.assertEqual(result['result'],'FAILED_TRANSPORT')
        self.assertFalse(result['lossless_storage'])

    def test_partial_record_with_zero_exit_is_not_a_pass(self):
        self.source.write_bytes(self.payload[:-1])
        result=recorder.record(self.root,self.child(),seconds=5,idle_seconds=2)
        self.assertEqual(result['reader_exit'],0)
        self.assertEqual(result['frames'],1)
        self.assertEqual(result['result'],'FAILED_TRANSPORT')

    def test_eof_without_native_exit_is_bounded_and_reaped(self):
        result=recorder.record(self.root,self.child('os.close(1); time.sleep(10)'),seconds=.2,idle_seconds=.2)
        self.assertEqual(result['result'],'FAILED_TRANSPORT')
        self.assertLess(result['elapsed_seconds'],2)
        self.assertNotEqual(result['reader_exit'],0)

    def test_idle_child_is_bounded_and_reaped(self):
        result=recorder.record(self.root,[sys.executable,'-B','-c','import time; time.sleep(10)'],seconds=2,idle_seconds=.1)
        self.assertEqual(result['result'],'FAILED_TRANSPORT')
        self.assertLess(result['elapsed_seconds'],2)
        self.assertNotEqual(result['reader_exit'],0)

    def test_keyboard_interrupt_is_not_a_pass(self):
        with mock.patch.object(recorder.select,'select',side_effect=KeyboardInterrupt):
            result=recorder.record(self.root,self.child(),seconds=2,idle_seconds=1)
        self.assertEqual(result['result'],'FAILED_TRANSPORT')
        self.assertIn('KeyboardInterrupt',result['error'])

    def test_existing_output_is_not_replaced(self):
        previous=self.root/'raw.vcap.gz';previous.write_bytes(b'keep')
        with mock.patch.object(recorder.subprocess,'Popen') as launch,self.assertRaises(FileExistsError):
            recorder.record(self.root,self.child())
        launch.assert_not_called()
        self.assertEqual(previous.read_bytes(),b'keep')

    def test_insufficient_disk_refuses_before_launch(self):
        with mock.patch.object(recorder.shutil,'disk_usage',return_value=mock.Mock(free=recorder.DISK_RESERVE)),mock.patch.object(recorder.subprocess,'Popen') as launch,self.assertRaises(ValueError):
            recorder.record(self.root,self.child())
        launch.assert_not_called()

    def test_running_disk_reserve_failure_is_not_a_pass(self):
        with mock.patch.object(recorder.shutil,'disk_usage',side_effect=[
                mock.Mock(free=4*1024**3),mock.Mock(free=recorder.DISK_RESERVE-1)]):
            result=recorder.record(self.root,self.child(),seconds=2,idle_seconds=1)
        self.assertEqual(result['result'],'FAILED_TRANSPORT')
        self.assertIn('disk reserve',result['error'])

    def test_raw_limit_rejection_records_received_and_stored_separately(self):
        with mock.patch.object(recorder,'MAX_RAW',1):
            result=recorder.record(self.root,self.child(),seconds=2,idle_seconds=1)
        self.assertEqual(result['result'],'FAILED_TRANSPORT')
        self.assertGreater(result['received_bytes'],0)
        self.assertEqual(result['raw_bytes'],0)
        self.assertFalse(result['lossless_storage'])

    def test_archive_limit_cannot_be_bypassed_by_clean_eof(self):
        with mock.patch.object(recorder,'MAX_ARCHIVE',1):
            result=recorder.record(self.root,self.child(),seconds=2,idle_seconds=1)
        self.assertEqual(result['result'],'FAILED_TRANSPORT')
        self.assertFalse(result['lossless_storage'])

    def test_native_launch_failure_is_retained(self):
        result=recorder.record(self.root,[str(self.root/'missing-executable')],seconds=2,idle_seconds=1)
        self.assertEqual(result['result'],'FAILED_TRANSPORT')
        self.assertIsNone(result['reader_exit'])
        self.assertFalse(result['lossless_storage'])

    def test_deadlines_cannot_exceed_board_watch_envelope(self):
        for seconds,idle in ((4501,650),(4500,651),(0,1),(1,0)):
            with self.subTest(seconds=seconds,idle=idle),mock.patch.object(recorder.subprocess,'Popen') as launch,self.assertRaises(ValueError):
                recorder.record(self.root,self.child(),seconds=seconds,idle_seconds=idle)
            launch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
