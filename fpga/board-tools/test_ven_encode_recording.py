"""Tiny native codec/parser tests; no guest, board, Vivado or accepted workload."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import ven_encode_recording as encoder
import ven_record_stream as transport
from test_ven_record_stream import HEADER, frame
from ven_vga_stream_to_video import rgb332_to_rgb24


class RecordingTests(unittest.TestCase):
    def setUp(self):
        scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
        if scratch != Path('/home/yukidama/external/tmp').resolve(strict=True):
            raise RuntimeError('use the external TMPDIR')
        temporary = tempfile.TemporaryDirectory(prefix='ventium-movie-test.', dir=scratch)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.capture = self.root/'capture'; self.capture.mkdir()
        self.output = self.root/'output'; self.output.mkdir()
        self.raw = HEADER+frame()+frame(3,2,2)
        self.archive = self.capture/'raw.vcap.gz'
        self.archive.write_bytes(gzip.compress(self.raw, mtime=0))
        self.receipt = dict(result='PASS_CLOSED_FRAME_TRANSPORT', reader_exit=0, error=None,
            lossless_storage=True, partial_bytes=0, frames=2, raw_bytes=len(self.raw),
            received_bytes=len(self.raw), raw_sha256=hashlib.sha256(self.raw).hexdigest(),
            first=dict(sequence=1,host_ns=1,cycles=1), last=dict(sequence=3,host_ns=2,cycles=2),
            acceptance=False, full_timedemo=False, gameplay_ipc=None)
        self.save_receipt()

    def save_receipt(self):
        (self.capture/'transport-closed.json').write_text(json.dumps(self.receipt))

    def test_streamed_frames_and_exact_palette(self):
        result = list(encoder.frames(self.capture, self.receipt))
        self.assertEqual(result, [bytes(range(256))*250]*2)
        self.assertEqual(b''.join(encoder.RGB_TABLE), rgb332_to_rgb24(bytes(range(256))))

    def test_reject_failed_or_inconsistent_transport(self):
        for update in (dict(result='FAILED_TRANSPORT'), dict(reader_exit=1), dict(error='failure'),
                       dict(lossless_storage=False), dict(partial_bytes=1), dict(frames=0),
                       dict(frames=32769), dict(frames=True), dict(received_bytes=1),
                       dict(raw_bytes=transport.MAX_RAW+1), dict(raw_sha256='0'*64),
                       dict(first=dict(sequence=0,host_ns=1,cycles=1))):
            with self.subTest(update=update), self.assertRaises(ValueError):
                list(encoder.frames(self.capture, dict(self.receipt, **update)))

    def test_corrupt_crc_gzip_truncation_and_extra_record(self):
        for raw in (self.raw[:-1], self.raw+b'x', self.raw[:-1]+b'X', HEADER+frame(width=319)):
            self.archive.write_bytes(gzip.compress(raw, mtime=0))
            with self.subTest(length=len(raw)), self.assertRaises(ValueError):
                list(encoder.frames(self.capture, self.receipt))
        self.archive.write_bytes(gzip.compress(self.raw, mtime=0)[:-4])
        with self.assertRaises(EOFError):
            list(encoder.frames(self.capture, self.receipt))

    def test_archive_size_bound(self):
        with mock.patch.object(transport, 'MAX_ARCHIVE', 1), self.assertRaises(ValueError):
            list(encoder.frames(self.capture, self.receipt))

    def test_recording_larger_than_old_32_mib_limit_streams(self):
        digest = hashlib.sha256(HEADER)
        size = len(HEADER)
        with gzip.GzipFile(filename=str(self.archive), mode='wb', mtime=0) as output:
            output.write(HEADER)
            for index in range(1,601):
                record = frame(index,index,index)
                output.write(record); digest.update(record); size += len(record)
        receipt = dict(self.receipt, frames=600, raw_bytes=size, received_bytes=size,
                       raw_sha256=digest.hexdigest(), last=dict(sequence=600,host_ns=600,cycles=600))
        self.assertGreater(size, 32*1024**2)
        self.assertEqual(sum(1 for _ in encoder.frames(self.capture,receipt)),600)

    def test_source_mutation_rejected(self):
        stream = encoder.frames(self.capture,self.receipt)
        next(stream)
        value = self.archive.stat()
        os.utime(self.archive,ns=(value.st_atime_ns,value.st_mtime_ns+1))
        with self.assertRaises(ValueError): list(stream)

    def test_symlink_refused(self):
        held = self.capture/'held.gz'
        self.archive.rename(held); self.archive.symlink_to(held)
        with self.assertRaises(ValueError): list(encoder.frames(self.capture, self.receipt))

    def test_native_lossless_movie_is_not_acceptance(self):
        result = encoder.encode(self.capture, self.output, seconds=30)
        if result['result'] != 'PASS_LOSSLESS_RECORDED_FRAMES_ONLY':
            detail = {p.name:p.read_text() for p in self.output.glob('*.stderr')}
            self.fail((result, detail))
        self.assertEqual(result['frames'], 2)
        self.assertEqual(result['presentation_fps'], 15)
        self.assertEqual(result['rgb24_sha256'], result['decoded_rgb24_sha256'])
        self.assertFalse(result['acceptance']); self.assertFalse(result['full_timedemo'])
        self.assertIsNone(result['gameplay_ipc'])
        with self.assertRaises(FileExistsError): encoder.encode(self.capture, self.output)

    def test_native_bad_source_leaves_failed_receipt(self):
        self.receipt['raw_sha256'] = '0'*64; self.save_receipt()
        result = encoder.encode(self.capture, self.output, seconds=30)
        self.assertEqual(result['result'], 'FAILED_MOVIE')
        self.assertFalse(result['acceptance']); self.assertFalse(result['full_timedemo'])

    def test_native_encoder_failure_is_not_success(self):
        # The interpreter rejects FFmpeg options; exercise real child exit/cleanup.
        with mock.patch.object(encoder.shutil,'which',return_value=sys.executable):
            result = encoder.encode(self.capture,self.output,seconds=30)
        self.assertEqual(result['result'],'FAILED_MOVIE')
        self.assertFalse(result['acceptance'])

    def test_cadence_metadata_rejects_dropped_frames_and_resize(self):
        base = dict(width=320,height=200,r_frame_rate='15/1',avg_frame_rate='15/1',
                    nb_frames='2',duration='0.133333')
        encoder.check_movie_probe(dict(streams=[base]), 2)
        for key,value in (('width',160),('height',100),('r_frame_rate','30/1'),
                          ('avg_frame_rate','30/1'),('nb_frames','1'),
                          ('duration','nan'),('duration','inf'),('duration','0.1')):
            with self.subTest(key=key,value=value), self.assertRaises(ValueError):
                encoder.check_movie_probe(dict(streams=[dict(base,**{key:value})]), 2)

    def test_disk_guard(self):
        with mock.patch.object(encoder.shutil,'disk_usage',return_value=mock.Mock(free=1)), self.assertRaises(ValueError):
            encoder.encode(self.capture,self.output)
        self.assertEqual(list(self.output.iterdir()), [])

    def test_stage_bounds(self):
        with self.assertRaises(TimeoutError): encoder.remaining(time.monotonic()-1)
        for seconds in (0,1801):
            with self.assertRaises(ValueError): encoder.encode(self.capture,self.output,seconds=seconds)

    def test_native_blocked_writer_and_decoder_are_bounded(self):
        for writing in (True,False):
            child = subprocess.Popen([sys.executable,'-B','-c','import time; time.sleep(5)'],
                                     stdin=subprocess.PIPE,stdout=subprocess.PIPE)
            try:
                with self.assertRaises(TimeoutError):
                    if writing:
                        encoder.write_frame(child,b'x'*100000,time.monotonic()+0.05,self.output)
                    else:
                        encoder.decode_hash(child,100000,time.monotonic()+0.05)
            finally: encoder.stop(child)
            self.assertIsNotNone(child.poll())

    def test_native_short_extra_or_failing_decoder(self):
        for size,exit_code in ((9,0),(11,0),(10,1)):
            child = subprocess.Popen([sys.executable,'-B','-c',
                f'import sys; sys.stdout.buffer.write(b"x"*{size}); sys.exit({exit_code})'],stdout=subprocess.PIPE)
            try:
                with self.subTest(size=size,exit_code=exit_code), self.assertRaises(ValueError):
                    encoder.decode_hash(child,10,time.monotonic()+3)
            finally: encoder.stop(child)


if __name__ == '__main__':
    unittest.main()
