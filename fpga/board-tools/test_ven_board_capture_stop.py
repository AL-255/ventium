#!/usr/bin/env python3
"""Mock I/O plus own-PID POSIX signal tests; no board or subprocess/guest I/O."""
import argparse
from contextlib import ExitStack
import importlib.util
import io
import os
from pathlib import Path
import signal
import struct
import sys
import unittest
from unittest.mock import patch
import zlib

sys.dont_write_bytecode = True
SOURCE = Path(__file__).resolve().with_name("ven_board_probe.py")
SPEC = importlib.util.spec_from_file_location("capture_stop_probe", SOURCE)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)
CAPTURE = PROBE._capture_scanout_frame
PACK_INTO = struct.pack_into
# Keep the real POSIX functions before the fixture patches the shared modules.
NATIVE_SIGNAL = signal.signal
NATIVE_GETSIGNAL = signal.getsignal
NATIVE_KILL = os.kill


class FakeCtrl(bytearray):
    def __init__(self, owner):
        super().__init__(1024)
        self.owner = owner

    def close(self):
        self.owner.ctrl_closes += 1
        if self.owner.cleanup_error == "ctrl":
            raise OSError("mock ctrl close failure")


class BinaryOutput:
    def __init__(self, owner):
        self.owner = owner
        self.data = bytearray()
        self.writes = 0
        self.flushes = 0

    def write(self, data):
        self.writes += 1
        phase = "stream_header" if self.writes == 1 else (
            "frame_header" if self.writes % 2 == 0 else "payload")
        # Request a stop halfway through write(), not only afterwards.
        split = len(data) // 2
        self.data.extend(data[:split])
        self.owner.trigger(phase)
        if self.owner.write_error == phase:
            raise BrokenPipeError("mock consumer loss")
        self.data.extend(data[split:])
        return len(data)

    def flush(self):
        self.flushes += 1
        phase = "header_flush" if self.flushes == 1 else "frame_flush"
        self.owner.trigger(phase)
        if self.owner.write_error == phase:
            raise BrokenPipeError("mock flush failure")


class TextOutput(io.StringIO):
    def __init__(self, owner):
        super().__init__()
        self.owner = owner

    def write(self, text):
        if text.startswith("VGA FRAME "):
            self.owner.trigger("progress")
        return super().write(text)


class Harness:
    def __init__(self, *, phase=None, enabled=True, plan=None, actual=None, native=False):
        self.args = argparse.Namespace(
            mode="vga-capture", func=PROBE.vga_capture_probe, frames=3,
            width=2, height=2, stream=True, output=None, skip_unmatched=False,
            frame_timeout=600.0, poll_interval=0.002, stop_on_sigusr1=enabled,
        )
        self.phase = phase
        self.plan = list(plan or [])
        self.actual = actual
        self.dimensions = (2, 2)
        self.pixel_count = 4
        self.monotonic = lambda: 0
        self.native = native
        self.native_handler_after = None
        self.native_original_restored = False
        self.repeat = 1
        self.fired = False
        self.stop_requests_sent = 0
        self.previous = lambda _signum, _frame: None
        self.handler = self.previous
        self.signal_calls = []
        self.captures = 0
        self.opens = 0
        self.ctrl_closes = 0
        self.fd_closes = []
        self.ctrl_writes = []
        self.status_reads = 0
        self.open_error = None
        self.install_error = None
        self.cleanup_error = None
        self.write_error = None
        self.ctrl = FakeCtrl(self)
        self.binary = BinaryOutput(self)
        self.stdout = io.StringIO()
        self.stdout.buffer = self.binary
        self.stderr = TextOutput(self)

    def trigger(self, phase):
        if phase == self.phase and not self.fired:
            self.fired = True
            for _ in range(self.repeat):
                if self.native:
                    # Never signal an unregistered/default handler. Only this
                    # test process is targeted, after the opt-in installation.
                    assert self.args.stop_on_sigusr1
                    assert callable(self.handler) and self.handler is not self.previous
                    assert NATIVE_GETSIGNAL(signal.SIGUSR1) is self.handler
                    NATIVE_KILL(os.getpid(), signal.SIGUSR1)
                else:
                    self.handler(signal.SIGUSR1, None)
                self.stop_requests_sent += 1

    def set_signal(self, signum, handler):
        assert signum == signal.SIGUSR1
        if self.install_error and not self.signal_calls:
            self.signal_calls.append((signum, handler))
            raise self.install_error
        previous = NATIVE_SIGNAL(signum, handler) if self.native else self.handler
        self.handler = handler
        self.signal_calls.append((signum, handler))
        return previous

    def open_mmio(self, **kwargs):
        assert kwargs == {"writable": True}
        self.opens += 1
        self.trigger("before_header")
        if self.open_error:
            raise self.open_error
        return 333, self.ctrl, None

    def close_fd(self, fd):
        assert fd == 333, "a real descriptor must never be closed"
        self.fd_closes.append(fd)
        if self.cleanup_error == "fd":
            raise OSError("mock fd close failure")

    def capture(self, ctrl, **kwargs):
        assert ctrl is self.ctrl
        self.captures += 1
        self.trigger("capture")
        if self.actual:
            return CAPTURE(ctrl, **kwargs)
        value = self.plan.pop(0) if self.plan else (
            self.captures, self.captures * 100, 2, 2, 4, b"\x00\x01\x02\x03")
        if isinstance(value, BaseException):
            raise value
        return value

    def u32(self, ctrl, offset):
        assert ctrl is self.ctrl
        if offset == PROBE.R_CAP_STATUS:
            self.status_reads += 1
            if self.status_reads == 1:
                return 0
            if self.status_reads == 2 or self.actual == "timeout":
                self.trigger("ready_wait")
                return PROBE.CAP_STATUS_ACTIVE
            return PROBE.CAP_STATUS_READY | 1
        if offset == PROBE.R_CAP_DIMS:
            return self.dimensions[0] | (self.dimensions[1] << 12)
        if offset == PROBE.R_CAP_PIXELS:
            return self.pixel_count
        if offset == PROBE.R_CAP_DATA:
            self.trigger("drain")
            if self.actual == "drain_error":
                raise OSError("mock BRAM drain failure")
            return 0x03020100
        raise AssertionError(f"unexpected mock MMIO read: {offset:x}")

    def pack_into(self, fmt, buffer, offset, value):
        if buffer is self.ctrl:
            self.ctrl_writes.append((offset, value))
        PACK_INTO(fmt, buffer, offset, value)

    def run(self):
        if not self.native:
            return self.run_patched()
        original = NATIVE_GETSIGNAL(signal.SIGUSR1)
        try:
            # A harmless saved-previous sentinel protects the process even if
            # the DUT's restoration is wrong; the assertion still catches it.
            NATIVE_SIGNAL(signal.SIGUSR1, self.previous)
            return self.run_patched()
        finally:
            try:
                self.native_handler_after = NATIVE_GETSIGNAL(signal.SIGUSR1)
            finally:
                NATIVE_SIGNAL(signal.SIGUSR1, original)
                self.native_original_restored = NATIVE_GETSIGNAL(signal.SIGUSR1) is original

    def run_patched(self):
        with ExitStack() as stack:
            for target, name, replacement in (
                (PROBE, "parse_args", lambda: self.args),
                (PROBE, "open_mmio", self.open_mmio),
                (PROBE, "_capture_scanout_frame", self.capture),
                (PROBE, "u32", self.u32),
                (PROBE, "stable_u64", lambda *args: 100),
                (PROBE.os, "close", self.close_fd),
                (PROBE.signal, "getsignal", lambda signum: (
                    NATIVE_GETSIGNAL(signum) if self.native else self.handler)),
                (PROBE.signal, "signal", self.set_signal),
                (PROBE.struct, "pack_into", self.pack_into),
                (PROBE.sys, "stdout", self.stdout),
                (PROBE.sys, "stderr", self.stderr),
                (PROBE.time, "sleep", lambda seconds: None),
                (PROBE.time, "monotonic_ns", lambda: self.captures * 1000),
            ):
                stack.enter_context(patch.object(target, name, replacement))
            if self.actual == "timeout":
                stack.enter_context(patch.object(PROBE.time, "monotonic", side_effect=[0, 1000]))
            else:
                stack.enter_context(patch.object(PROBE.time, "monotonic", side_effect=self.monotonic))
            return PROBE.main()


class CaptureStopTests(unittest.TestCase):
    def assert_restored(self, harness):
        self.assertIs(harness.handler, harness.previous)
        if harness.native:
            self.assertIs(harness.native_handler_after, harness.previous)
            self.assertTrue(harness.native_original_restored)
        if harness.args.stop_on_sigusr1 and harness.previous is not None:
            self.assertEqual(len(harness.signal_calls), 2)
            self.assertIs(harness.signal_calls[-1][1], harness.previous)
        else:
            self.assertEqual(harness.signal_calls, [])

    def assert_records(self, harness, expected):
        raw = bytes(harness.binary.data)
        header = PROBE.VCAP_STREAM_HEADER
        magic, version, declared = header.unpack(raw[:header.size])
        self.assertEqual((magic, version, declared), (b"VENVCAP1", 1, harness.args.frames))
        cursor = header.size
        count = 0
        while cursor < len(raw):
            frame = PROBE.VCAP_FRAME_HEADER
            packed = raw[cursor:cursor + frame.size]
            self.assertEqual(len(packed), frame.size, "partial frame header")
            marker, seq, host_ns, cycle, width, height, pixels, crc = frame.unpack(packed)
            cursor += frame.size
            payload = raw[cursor:cursor + pixels]
            self.assertEqual(len(payload), pixels, "partial payload")
            self.assertEqual((marker, width, height, pixels), (b"VFRM", 2, 2, 4))
            self.assertEqual(zlib.crc32(payload) & 0xffffffff, crc)
            self.assertGreater(seq, 0)
            self.assertGreater(host_ns, 0)
            self.assertGreater(cycle, 0)
            cursor += pixels
            count += 1
        self.assertEqual(count, expected)

    def test_stop_at_each_record_phase(self):
        before = ("before_header", "stream_header", "header_flush")
        during = ("capture", "frame_header", "payload", "frame_flush", "progress")
        for native in (False, True):
            for phase in before + during:
                with self.subTest(native=native, phase=phase):
                    h = Harness(phase=phase, native=native)
                    self.assertEqual(h.run(), 0)
                    count = 0 if phase in before else 1
                    self.assertEqual(h.captures, count)
                    self.assertEqual(h.stop_requests_sent, 1)
                    self.assert_records(h, count)
                    self.assertIn(f"reason=SIGUSR1 completed={count} requested=3", h.stderr.getvalue())
                    self.assertIn("NOT timedemo or temporal-coverage acceptance", h.stderr.getvalue())
                    self.assertEqual(h.ctrl_closes, 1)
                    self.assertEqual(h.fd_closes, [333])
                    self.assert_restored(h)

    def test_ready_wait_finishes_actual_mock_frame(self):
        for native in (False, True):
            with self.subTest(native=native):
                h = Harness(phase="ready_wait", actual="valid", native=native)
                self.assertEqual(h.run(), 0)
                self.assertEqual(h.captures, 1)
                self.assertEqual(h.status_reads, 3)
                self.assert_records(h, 1)
                self.assertEqual(h.ctrl_writes, [(PROBE.R_CAP_CTL, 1), (PROBE.R_CAP_ADDR, 0)])
                self.assert_restored(h)

    def test_drain_finishes_without_abort_write(self):
        for native in (False, True):
            with self.subTest(native=native):
                h = Harness(phase="drain", actual="valid", native=native)
                self.assertEqual(h.run(), 0)
                self.assert_records(h, 1)
                self.assertEqual(h.ctrl_writes, [(PROBE.R_CAP_CTL, 1), (PROBE.R_CAP_ADDR, 0)])
                self.assert_restored(h)

    def test_repeated_requests_are_idempotent(self):
        for native in (False, True):
            with self.subTest(native=native):
                h = Harness(phase="frame_header", native=native)
                h.repeat = 3
                self.assertEqual(h.run(), 0)
                self.assertEqual(h.stop_requests_sent, 3)
                self.assertEqual(h.captures, 1)
                self.assert_records(h, 1)
                self.assert_restored(h)

    def test_stop_after_filtered_frame(self):
        for value in (
            (1, 100, 4, 1, 4, b"abcd"),
            RuntimeError("VGA recorder overflowed its private frame BRAM"),
        ):
            with self.subTest(value=value):
                h = Harness(phase="capture", plan=[value])
                h.args.skip_unmatched = True
                self.assertEqual(h.run(), 0)
                self.assertEqual(h.captures, 1)
                self.assert_records(h, 0)  # Empty prefix is not movie acceptance.
                self.assertIn("completed=0 requested=3", h.stderr.getvalue())
                self.assert_restored(h)

    def test_capture_faults_after_request_stay_nonzero(self):
        for error in (
            RuntimeError("VGA recorder is already active; refusing to overlap captures"),
            RuntimeError("invalid frozen VGA metadata"),
            RuntimeError("VGA recorder overflowed its private frame BRAM"),
        ):
            with self.subTest(error=error):
                h = Harness(phase="capture", plan=[error])
                self.assertEqual(h.run(), 2)
                self.assertNotIn("VGA CAPTURE STOP", h.stderr.getvalue())
                self.assert_restored(h)

    def test_nonrequested_startup_metadata_is_filtered_without_emission(self):
        h = Harness(plan=[PROBE.CaptureMetadataError(1, 128, 3, 360)])
        h.args.skip_unmatched = True
        self.assertEqual(h.run(), 0)
        self.assertEqual(h.captures, 4)
        self.assert_records(h, 3)
        self.assertIn("no payload emitted", h.stderr.getvalue())
        self.assert_restored(h)

    def test_actual_metadata_filter_never_drains_invalid_payload(self):
        h = Harness(phase="ready_wait", actual="valid")
        h.dimensions = (128, 3)
        h.pixel_count = 360
        h.args.skip_unmatched = True
        self.assertEqual(h.run(), 0)
        self.assert_records(h, 0)
        self.assertEqual(h.ctrl_writes, [(PROBE.R_CAP_CTL, 1)])
        self.assert_restored(h)

    def test_startup_filter_requires_explicit_geometry_and_optin(self):
        for skip, dimensions in ((False, (2, 2)), (True, (0, 0))):
            with self.subTest(skip=skip, dimensions=dimensions):
                h = Harness(plan=[PROBE.CaptureMetadataError(1, 128, 3, 360)])
                h.args.skip_unmatched = skip
                h.args.width, h.args.height = dimensions
                self.assertEqual(h.run(), 2)
                self.assert_records(h, 0)
                self.assert_restored(h)

    def test_requested_and_impossible_metadata_always_fail(self):
        for dimensions in ((2, 2, 3), (0, 3, 360), (128, 0, 360),
                           (128, 3, 0), (128, 3, PROBE.CAPTURE_MAX_BYTES + 1),
                           (4096, 3, 360)):
            with self.subTest(dimensions=dimensions):
                h = Harness(plan=[PROBE.CaptureMetadataError(1, *dimensions)])
                h.args.skip_unmatched = True
                self.assertEqual(h.run(), 2)
                self.assert_records(h, 0)
                self.assert_restored(h)

    def test_metadata_fault_after_first_requested_frame_is_fatal(self):
        valid = (1, 100, 2, 2, 4, b"abcd")
        h = Harness(plan=[valid, PROBE.CaptureMetadataError(2, 128, 3, 360)])
        h.args.skip_unmatched = True
        self.assertEqual(h.run(), 2)
        self.assert_records(h, 1)
        self.assertNotIn("startup VGA metadata", h.stderr.getvalue())
        self.assert_restored(h)

    def test_stop_after_startup_filter_emits_no_partial_record(self):
        h = Harness(phase="capture", plan=[PROBE.CaptureMetadataError(1, 128, 3, 360)])
        h.args.skip_unmatched = True
        self.assertEqual(h.run(), 0)
        self.assert_records(h, 0)
        self.assertEqual(h.captures, 1)
        self.assert_restored(h)

    def test_startup_metadata_retry_is_bounded(self):
        h = Harness(plan=[PROBE.CaptureMetadataError(1, 128, 3, 360),
                          PROBE.CaptureMetadataError(2, 128, 3, 360)])
        h.args.skip_unmatched = True
        ticks = iter((0, 601))
        h.monotonic = lambda: next(ticks)
        self.assertEqual(h.run(), 2)
        self.assert_records(h, 0)
        self.assertIn("did not settle before timeout", h.stderr.getvalue())
        self.assert_restored(h)

    def test_ready_timeout_after_request_stays_nonzero(self):
        h = Harness(phase="ready_wait", actual="timeout")
        self.assertEqual(h.run(), 2)
        self.assertIn("before timeout", h.stderr.getvalue())
        self.assertEqual(h.ctrl_writes, [(PROBE.R_CAP_CTL, 1)])
        self.assert_restored(h)

    def test_drain_error_after_request_stays_nonzero(self):
        h = Harness(phase="drain", actual="drain_error")
        self.assertEqual(h.run(), 2)
        self.assertIn("BRAM drain failure", h.stderr.getvalue())
        self.assertEqual(h.ctrl_writes, [(PROBE.R_CAP_CTL, 1), (PROBE.R_CAP_ADDR, 0)])
        self.assert_restored(h)

    def test_broken_pipe_after_request_stays_nonzero(self):
        for phase in ("stream_header", "header_flush", "frame_header", "payload", "frame_flush"):
            with self.subTest(phase=phase):
                h = Harness(phase=phase)
                h.write_error = phase
                self.assertEqual(h.run(), 2)
                self.assertNotIn("VGA CAPTURE STOP", h.stderr.getvalue())
                self.assert_restored(h)

    def test_keyboard_interrupt_is_not_swallowed(self):
        h = Harness(phase="capture", plan=[KeyboardInterrupt()])
        with self.assertRaises(KeyboardInterrupt):
            h.run()
        self.assertNotIn("VGA CAPTURE STOP", h.stderr.getvalue())
        self.assert_restored(h)

    def test_open_failure_restores_handler(self):
        h = Harness()
        h.open_error = OSError("mock MMIO open failure")
        self.assertEqual(h.run(), 2)
        self.assertEqual(h.ctrl_closes, 0)
        self.assertEqual(h.fd_closes, [])
        self.assert_restored(h)

    def test_handler_install_failure_preserves_previous_handler(self):
        h = Harness()
        h.install_error = RuntimeError("mock signal install failure")
        self.assertEqual(h.run(), 2)
        self.assertEqual(h.opens, 0)
        self.assert_restored(h)

    def test_cleanup_failure_still_restores_and_closes_fd(self):
        for failure in ("ctrl", "fd"):
            with self.subTest(failure=failure):
                h = Harness(phase="before_header")
                h.cleanup_error = failure
                self.assertEqual(h.run(), 2)
                self.assertEqual(h.ctrl_closes, 1)
                self.assertEqual(h.fd_closes, [333])
                self.assert_restored(h)

    def test_nonrestorable_handler_is_rejected_before_mmio(self):
        h = Harness()
        h.previous = h.handler = None
        self.assertEqual(h.run(), 2)
        self.assertEqual(h.opens, 0)
        self.assert_restored(h)

    def test_optout_and_natural_quota(self):
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                h = Harness(enabled=enabled)
                self.assertEqual(h.run(), 0)
                self.assert_records(h, 3)
                self.assertNotIn("VGA CAPTURE STOP", h.stderr.getvalue())
                self.assert_restored(h)

    def test_request_does_not_leak_to_next_invocation(self):
        for native in (False, True):
            with self.subTest(native=native):
                first = Harness(phase="progress", native=native)
                self.assertEqual(first.run(), 0)
                self.assert_records(first, 1)
                self.assert_restored(first)
                second = Harness(native=native)
                second.previous = second.handler = first.previous
                self.assertEqual(second.run(), 0)
                self.assert_records(second, 3)
                self.assertNotIn("VGA CAPTURE STOP", second.stderr.getvalue())
                self.assert_restored(second)

    def test_native_signal_cannot_hide_timeout_or_pipe_loss(self):
        cases = [("ready_wait", "timeout", None), ("drain", "drain_error", None)]
        cases += [(phase, None, phase) for phase in (
            "stream_header", "header_flush", "frame_header", "payload", "frame_flush")]
        for phase, actual, write_error in cases:
            with self.subTest(phase=phase, actual=actual):
                h = Harness(phase=phase, actual=actual, native=True)
                h.write_error = write_error
                self.assertEqual(h.run(), 2)
                self.assertEqual(h.stop_requests_sent, 1)
                self.assertNotIn("VGA CAPTURE STOP", h.stderr.getvalue())
                self.assert_restored(h)

    def test_default_and_ignored_handlers_are_restored(self):
        for previous in (signal.SIG_DFL, signal.SIG_IGN):
            with self.subTest(previous=previous):
                h = Harness(phase="frame_flush")
                h.previous = h.handler = previous
                self.assertEqual(h.run(), 0)
                self.assert_records(h, 1)
                self.assert_restored(h)

    def test_parser_flag_is_opt_in(self):
        for flags, enabled in (([], False), (["--stop-on-sigusr1"], True)):
            with self.subTest(enabled=enabled):
                with patch.object(sys, "argv", [str(SOURCE), "vga-capture", "--stream", *flags]):
                    args = PROBE.parse_args()
                self.assertIs(args.stop_on_sigusr1, enabled)
                self.assertIs(args.func, PROBE.vga_capture_probe)


if __name__ == "__main__":
    unittest.main(verbosity=2)
