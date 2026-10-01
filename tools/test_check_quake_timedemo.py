"""Read-only acceptance tests; no RTL simulation or guest is launched."""
import hashlib
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import check_quake_timedemo as q


STARTUP = b"Console initialized.\r\nPlaying demo from demo1.dem.\r\nThe Necropolis\r\n"
RESULT = b"969 frames 12.3 seconds 78.8 fps\r\n"
RESET = b">>> ventium-soc: reset released; running up to 30000000000 cycles\n"
DONE = RESET + b">>> done: cyc=123456 retires=3456 last cs=0008:eip=00012345\n"


def progress(cycle, retired):
    return (f"[{cycle:10d}] retires={retired} cs=00a7:eip=00010574 "
            "cr0=80000011 cr3=0003d000 eflags=00003206\n").encode()


def footer(cycle, retired):
    return f">>> done: cyc={cycle} retires={retired} last cs=00a7:eip=00010574\n".encode()


class QuakeAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.disk = Path(self.temp.name) / "disk.vhd"
        self.receipt = {"schema": 1, "partition_offset": 32256, "disk_sha256": "0" * 64,
                        "qconsole_sha256": hashlib.sha256(STARTUP).hexdigest(), "results": []}

    def check(self, console, log=DONE, **kwargs):
        with mock.patch.object(q, "read_console", return_value=(32256, console)), \
                mock.patch.object(q, "digest", return_value="1" * 64):
            return q.check(self.disk, self.receipt, log, **kwargs)

    def test_startup_gameplay_and_cycle_exit_are_not_completion(self):
        for console in (STARTUP, STARTUP + b"timedemo demo1\n", b"", b"%i frames %f seconds %f fps\n"):
            self.assertEqual(self.check(console, stopped=True, returncode=0)["status"], "PENDING")

    def test_fresh_stopped_completion(self):
        result = self.check(STARTUP + RESULT, stopped=True, returncode=0)
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["result"], {"frames": 969, "seconds": "12.3", "fps": "78.8"})

    def test_live_result_never_passes(self):
        self.assertEqual(self.check(STARTUP + RESULT)["status"], "OBSERVED_UNQUALIFIED")

    def test_snapshot_or_unidentified_demo_cannot_qualify_cold_demo1(self):
        for console, log in ((RESULT, DONE),
                             (STARTUP + RESULT, b">>> STATE LOADED from old.snap @cyc=1000\n" + DONE)):
            with self.subTest(console=console, log=log), self.assertRaises(ValueError):
                self.check(console, log, stopped=True, returncode=0)

    def test_malformed_baseline_fails_closed(self):
        for receipt in ([], None, {"schema": 1}, dict(self.receipt, disk_sha256="not a hash")):
            self.receipt = receipt
            with self.subTest(receipt=receipt), self.assertRaises(ValueError):
                self.check(STARTUP + RESULT, stopped=True, returncode=0)

    def test_preexisting_baseline_result_rejected(self):
        with mock.patch.object(q, "read_console", return_value=(32256, STARTUP + RESULT)):
            with self.assertRaisesRegex(ValueError, "already contains"):
                q.baseline(self.disk)
        self.receipt["results"] = [{"frames": 969}]
        with self.assertRaisesRegex(ValueError, "unclean"):
            self.check(STARTUP + RESULT, stopped=True, returncode=0)

    def test_unchanged_result_cannot_pass(self):
        self.receipt["qconsole_sha256"] = hashlib.sha256(STARTUP + RESULT).hexdigest()
        self.assertEqual(self.check(STARTUP + RESULT, stopped=True, returncode=0)["status"], "PENDING")

    def test_bad_result_fields(self):
        for line in (b"968 frames 12.3 seconds 78.8 fps\n", b"969 frames 0 seconds 78.8 fps\n",
                     b"969 frames 12.3 seconds 0 fps\n", b"969 frames 12.3 seconds 500 fps\n"):
            with self.subTest(line=line), self.assertRaises(ValueError):
                self.check(STARTUP + line, stopped=True, returncode=0)

    def test_normal_exit_and_complete_log_required(self):
        for code, log in ((124, DONE), (-9, DONE), (None, DONE), (0, b""),
                          (0, DONE.replace(b"retires=3456", b"retires=0"))):
            with self.subTest(code=code, log=log), self.assertRaises(ValueError):
                self.check(STARTUP + RESULT, log, stopped=True, returncode=code)

    def test_truncated_progress_then_recovered_output_cannot_pass(self):
        # Exact class of the observed quota failure: new stderr starts inside
        # the prior record's truncated eflags field, then clean exit/result.
        log = (RESET + progress(2364747136, 823644193) +
               progress(2365247136, 823965360).split(b"eflags=")[0] + b"eflags=0000" +
               progress(2497747136, 883222045) + footer(9000000000, 3000000000))
        with self.assertRaisesRegex(ValueError, "incomplete progress"):
            self.check(STARTUP + RESULT, log, stopped=True, returncode=0)

    def test_progress_prefixed_by_buffered_stdout_is_valid(self):
        log = (RESET + b"tb: FLT vec=80 cs=0028 eip=c00012" + progress(54348660, 1000000) +
               b"  |[1] numerical guest text\n" + progress(55348660, 1100000) + footer(55348660, 1100000))
        self.assertEqual(self.check(STARTUP + RESULT, log, stopped=True, returncode=0)["status"], "PASS")

    def test_large_progress_gap_is_not_itself_an_architectural_failure(self):
        # Nested host IDE polling has no static upper tick bound. Parsing must
        # not manufacture a failure by assuming 500K+small fixed overshoot.
        log = RESET + progress(500000, 100000) + progress(5000000000, 2000000000) + footer(9000000000, 3000000000)
        result = self.check(STARTUP + RESULT, log, stopped=True, returncode=0)
        self.assertEqual(result["status"], "PASS")
        self.assertTrue(result["log_records"]["maximum_progress_interval_not_bounded"])

    def test_missing_reset_duplicate_footer_and_unterminated_footer_fail(self):
        for log in (DONE[len(RESET):], DONE + footer(200000, 4000), DONE[:-1], RESET + DONE,
                    RESET + footer(500000, 100000)):
            with self.subTest(log=log), self.assertRaises(ValueError):
                self.check(STARTUP + RESULT, log, stopped=True, returncode=0)

    def test_reset_cap_must_fit_the_native_uint64_producer(self):
        for cap in (b"0", b"18446744073709551616"):
            with self.subTest(cap=cap), self.assertRaises(ValueError):
                self.check(STARTUP + RESULT, DONE.replace(b"30000000000", cap), stopped=True, returncode=0)

    def test_out_of_order_progress_or_final_counters_fail(self):
        cases = (progress(500000, 100000) + progress(499999, 200000),
                 progress(500000, 100000) + progress(1000000, 99999),
                 progress(499999, 100000), progress(1500000, 300000),
                 progress(500000, 300001))
        for records in cases:
            with self.subTest(records=records), self.assertRaises(ValueError):
                self.check(STARTUP + RESULT, RESET + records + footer(1000000, 300000),
                           stopped=True, returncode=0)
        with self.assertRaises(ValueError):
            self.check(STARTUP + RESULT, DONE + progress(500000, 100000), stopped=True, returncode=0)

    def test_error_free_large_log_is_bounded_before_disk_read(self):
        with mock.patch.object(q, "ENGINE_LOG_MAX_BYTES", 4), mock.patch.object(q, "read_console") as read:
            with self.assertRaisesRegex(ValueError, "64 MiB"):
                q.check(self.disk, self.receipt, b"abcde", stopped=True, returncode=0)
            read.assert_not_called()

    def test_actual_errors_fail_but_guest_fault_probes_are_not_errors(self):
        for error in (b"%Error: core.sv: Assertion failed", b"SNAPSHOT-ERROR: disk flush", b"Sys_Error: bad",
                      b"Exiting due to signal SIGSEGV", b"General Protection Fault at eip=12345678"):
            with self.subTest(error=error), self.assertRaises(ValueError):
                self.check(STARTUP + RESULT, DONE + error, stopped=True, returncode=0)
        # Firmware/DPMI architectural probes may deliver #UD/#GP and recover.
        self.assertEqual(self.check(STARTUP + RESULT,
                         b"[VEN-UNK] d_unknown HALT\nint_vec=06 guest #GP delivered\n" + DONE,
                         stopped=True, returncode=0)["status"], "PASS")

    def test_dos_fatal_error_after_valid_result_cannot_pass(self):
        for error in (b"Error: failed writing configuration\r\n",
                      b"Error: Quake requires a floating-point processor\r\n",
                      b"  Error: fatal system error\n",
                      b"\tERROR: fatal system error\n"):
            for evidence in ("console", "engine"):
                with self.subTest(error=error, evidence=evidence), self.assertRaisesRegex(
                        ValueError, "terminal error"):
                    console = STARTUP + RESULT + (error if evidence == "console" else b"")
                    log = DONE + (error if evidence == "engine" else b"")
                    self.check(console, log, stopped=True, returncode=0)

    def test_dos_fatal_error_in_actual_vgatext_row_cannot_pass(self):
        for row in (b"  |Error: failed writing configuration\n",
                    b"  |Error: Quake requires a floating-point processor\n",
                    b"  |    Error: fatal system error\n"):
            log = b"[VGATEXT @500000 start=0000 stride=80; 80x25 character window]\n" + row + DONE
            with self.subTest(row=row), self.assertRaisesRegex(ValueError, "terminal error"):
                self.check(STARTUP + RESULT, log, stopped=True, returncode=0)

    def test_nonfatal_prose_containing_error_is_not_a_fatal_banner(self):
        for text in (b"Error count: 0\n", b"Warning: Error: example diagnostic only\n",
                     b"Diagnostic mentions Error: but does not fail\n",
                     b"  |Diagnostic mentions Error: but does not fail\n",
                     b"  |Error tolerance: 0.001\n"):
            with self.subTest(text=text):
                self.assertEqual(self.check(STARTUP + RESULT + text, DONE + text,
                                           stopped=True, returncode=0)["status"], "PASS")

    def test_changed_partition_rejected(self):
        self.receipt["partition_offset"] = 0
        with self.assertRaisesRegex(ValueError, "geometry changed"):
            self.check(STARTUP + RESULT, stopped=True, returncode=0)

    def make_disk(self):
        sectors, start = 12000, 63
        mbr = bytearray(512)
        mbr[510:] = b"\x55\xaa"
        mbr[446] = 0x80
        mbr[450] = 6
        struct.pack_into("<II", mbr, 454, start, sectors)
        boot = bytearray(512)
        boot[510:] = b"\x55\xaa"
        struct.pack_into("<HBHBHH", boot, 11, 512, 1, 1, 2, 512, sectors)
        struct.pack_into("<H", boot, 22, 48)
        # Use a sparse fixture; the helper reads only MBR/BPB, never modifies it.
        with self.disk.open("wb") as stream:
            stream.write(mbr)
            stream.seek(start * 512)
            stream.write(boot)
            stream.truncate((start + sectors) * 512)
        return mbr, boot

    def test_actual_mbr_bpb_offset_and_readonly_mtype_command(self):
        self.make_disk()
        before = q.digest(self.disk)
        self.assertEqual(q.fat16_offset(self.disk), 32256)
        with mock.patch.object(q, "_capture_bounded", return_value=mock.Mock(stdout=STARTUP)) as run:
            self.assertEqual(q.read_console(self.disk), (32256, STARTUP))
        self.assertEqual(run.call_args.args[0],
                         ["mtype", "-i", f"{self.disk.resolve()}@@32256", q.LOG_PATH])
        self.assertEqual(run.call_args.kwargs, {"stdout_limit": 16 * 1024 * 1024,
                                               "stderr_limit": 64 * 1024, "timeout": 15})
        self.assertEqual(before, q.digest(self.disk))

    def test_invalid_mbr_bpb_and_ambiguous_partitions_rejected(self):
        for offset, payload in ((510, b"xx"), (450, b"\x0b"), (462 + 4, b"\x06"),
                                (454, struct.pack("<I", 20000)), (32256 + 11, b"\x00\x04"),
                                (32256 + 13, b"\x03"), (32256 + 22, b"\x01\x00")):
            self.make_disk()
            with self.disk.open("r+b") as stream:
                stream.seek(offset)
                stream.write(payload)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                q.fat16_offset(self.disk)

    def test_missing_or_transient_console_never_passes(self):
        for error in (subprocess.CalledProcessError(1, ["mtype"]), subprocess.TimeoutExpired("mtype", 15)):
            with mock.patch.object(q, "read_console", side_effect=error), self.assertRaises(type(error)):
                q.check(self.disk, self.receipt, DONE, stopped=True, returncode=0)


class BoundedReaderTests(unittest.TestCase):
    """Tiny host-only pipe writers; never execute mtype or a guest."""

    def setUp(self):
        self.processes = []
        self.original_popen = subprocess.Popen

        def spawn(*args, **kwargs):
            process = self.original_popen(*args, **kwargs)
            self.processes.append(process)
            return process

        patcher = mock.patch.object(q.subprocess, "Popen", side_effect=spawn)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.assert_reaped)

    def assert_reaped(self):
        for process in self.processes:
            self.assertIsNotNone(process.returncode)
            self.assertTrue(process.stdout.closed)
            self.assertTrue(process.stderr.closed)
            with self.assertRaises(ChildProcessError):
                os.waitpid(process.pid, os.WNOHANG)

    def capture(self, code, *, stdout_limit=4, stderr_limit=4, timeout=2):
        return q._capture_bounded([sys.executable, "-B", "-c", code],
                                  stdout_limit=stdout_limit, stderr_limit=stderr_limit, timeout=timeout)

    def test_exact_limits_and_both_pipes(self):
        result = self.capture("import os; os.write(1,b'ab'); os.write(2,b'1234'); os.write(1,b'cd')")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"abcd", b"1234"))

    def test_stdout_overflow_kills_and_reaps_without_drain(self):
        with mock.patch.object(self.original_popen, "communicate",
                               side_effect=AssertionError("unbounded communicate forbidden")), \
                self.assertRaisesRegex(ValueError, "QCONSOLE.LOG exceeded"):
            self.capture("import os,time; os.write(1,b'abcde'); time.sleep(3600)")

    def test_stderr_flood_kills_and_reaps(self):
        with self.assertRaisesRegex(ValueError, "mtype stderr exceeded"):
            self.capture("import os; os.write(2,b'E'*1000000)")

    def test_timeout_with_open_pipes_has_bounded_partial_output(self):
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired) as caught:
            self.capture("import os,time; os.write(1,b'ok'); time.sleep(3600)", timeout=0.2)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual((caught.exception.output, caught.exception.stderr), (b"ok", b""))

    def test_timeout_also_covers_child_that_closes_both_pipes(self):
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            self.capture("import os,time; os.close(1); os.close(2); time.sleep(3600)", timeout=0.2)
        self.assertLess(time.monotonic() - started, 2)

    def test_normal_nonzero_exit_retains_bounded_diagnostics(self):
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.capture("import os,sys; os.write(1,b'out'); os.write(2,b'err'); sys.exit(7)")
        self.assertEqual((caught.exception.returncode, caught.exception.output, caught.exception.stderr),
                         (7, b"out", b"err"))


if __name__ == "__main__":
    unittest.main()
