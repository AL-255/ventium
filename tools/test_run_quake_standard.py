#!/usr/bin/env python3
"""Host-only runner tests; no guest simulation or external disk writes."""
import contextlib
import errno
import hashlib
import io
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_quake_standard as runner


class FakeProcess:
    def __init__(self, command, **kwargs):
        self.pid = 12345
        self.command = command
        self.environment = kwargs["env"]
        self.polls = self.waits = 0
        self.returncode = None
        self.assert_pipe = kwargs["stdout"] == subprocess.PIPE
        read_fd, write_fd = os.pipe()
        self.stdout = os.fdopen(read_fd, "rb", buffering=0)
        os.write(write_fd, b">>> done: cyc=500000 retires=100000 last cs=0010:eip=00010000\n")
        os.close(write_fd)

    def poll(self):
        self.polls += 1
        if self.polls > 1:
            self.returncode = 0
        return self.returncode

    def wait(self, **kwargs):
        self.waits += 1
        self.returncode = 0
        return self.returncode

    def terminate(self):
        self.returncode = -15

    def kill(self):
        self.returncode = -9


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ventium-quake-runner-test.")
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.disk = self.base / "source.vhd"
        self.disk.write_bytes(b"unchanged source guest disk")
        self.binary = self.base / "source-sim"
        self.binary.write_bytes(b"fake simulator; never executed")
        self.rom = self.base / "source-rom"
        self.rom.mkdir()
        for name in ("boot0.rom", "boot1.rom"):
            (self.rom / name).write_bytes(name.encode())
        self.args = SimpleNamespace(disk=self.disk, binary=self.binary, bios_dir=self.rom,
                                    out=self.base / "run", cpu=min(os.sched_getaffinity(0)),
                                    cycles=1_000_000, seconds=60)

    def exercise(self, live, final, *, group_present=False):
        processes = []
        checks = []

        def spawn(*args, **kwargs):
            process = FakeProcess(*args, **kwargs)
            processes.append(process)
            return process

        def check(disk, receipt, log, **kwargs):
            self.assertNotEqual(disk.resolve(), self.disk.resolve())
            checks.append(kwargs)
            if kwargs.get("stopped"):
                self.assertGreater(processes[0].waits, 0)
                self.assertEqual(kwargs["returncode"], 0)
                return final
            if isinstance(live, BaseException):
                raise live
            return live

        # Replace cp only; replacing Popen also affects subprocess.run, so
        # emulate its staging operation without starting any executable.
        def stage(command, **kwargs):
            self.assertEqual(command[:3], ["cp", "--sparse=always", "--"])
            runner.shutil.copy2(command[-2], command[-1])
            return subprocess.CompletedProcess(command, 0)

        with patch.object(runner.subprocess, "Popen", side_effect=spawn), \
                patch.object(runner.subprocess, "run", side_effect=stage), \
                patch.object(runner.gate, "baseline", return_value={"clean": True}), \
                patch.object(runner.gate, "check", side_effect=check), \
                patch.object(runner.os, "killpg", side_effect=None if group_present else ProcessLookupError), \
                patch.object(runner.time, "sleep"), \
                patch.dict(os.environ, {"VEN_IDE_DROP_WRITES": "1"}), \
                contextlib.redirect_stdout(io.StringIO()):
            code = runner.run(self.args)
        return code, processes, checks

    def test_fresh_observation_requires_closed_disk_recheck(self):
        before = runner.gate.digest(self.disk)
        code, processes, checks = self.exercise(
            {"status": "OBSERVED_UNQUALIFIED", "result": {"frames": 969}},
            {"status": "PASS", "result": {"frames": 969}})
        self.assertEqual(code, 0)
        self.assertEqual(checks, [{}, {"stopped": True, "returncode": 0}])
        self.assertTrue((self.args.out / "stop.request").is_file())
        self.assertEqual(runner.gate.digest(self.disk), before)
        self.assertNotIn("VEN_IDE_DROP_WRITES", processes[0].environment)
        self.assertIn("--stop-request", processes[0].command)
        self.assertFalse({"--restore", "--save-stop", "--save-at"} & set(processes[0].command))
        result = json.loads((self.args.out / "result.json").read_text())
        evidence = result["log_capture"]
        self.assertTrue(evidence["actual_child_wait"] and evidence["pipe_eof"])
        self.assertIsNone(evidence["sticky_error"])
        self.assertEqual(evidence["captured_bytes"], evidence["persisted_bytes"])
        self.assertEqual(evidence["sha256"], runner.gate.digest(self.args.out / "run.log"))
        self.assertTrue(processes[0].assert_pipe and processes[0].stdout.closed)
        self.assertTrue(result["process_group_absent_after_wait"])

    def test_cap_and_clean_exit_without_result_are_not_pass(self):
        code, _, _ = self.exercise({"status": "PENDING"}, {"status": "PENDING"})
        self.assertEqual(code, 2)
        result = json.loads((self.args.out / "result.json").read_text())
        self.assertEqual(result["status"], "FAIL")
        self.assertFalse((self.args.out / "stop.request").exists())

    def test_live_result_is_not_pass_if_final_read_disagrees(self):
        code, _, _ = self.exercise({"status": "OBSERVED_UNQUALIFIED"}, {"status": "PENDING"})
        self.assertEqual(code, 2)

    def test_existing_output_refused_before_source_mutation(self):
        self.args.out.mkdir()
        with self.assertRaisesRegex(ValueError, "refusing to reuse"):
            runner.run(self.args)
        self.assertEqual(list(self.args.out.iterdir()), [])

    def test_broken_output_symlink_refused(self):
        self.args.out.symlink_to(self.base / "absent-target")
        with self.assertRaisesRegex(ValueError, "output symlink"):
            runner.run(self.args)
        self.assertFalse((self.base / "absent-target").exists())

    def test_immutable_source_gets_writable_private_copy(self):
        self.disk.chmod(0o444)
        code, _, _ = self.exercise({"status": "PENDING"}, {"status": "PENDING"})
        self.assertEqual(code, 2)
        self.assertFalse(self.disk.stat().st_mode & 0o200)
        self.assertTrue((self.args.out / "guest.vhd").stat().st_mode & 0o200)

    def test_invalid_bounds_refused(self):
        self.args.seconds = 0
        with self.assertRaisesRegex(ValueError, "bounds must be positive"):
            runner.run(self.args)
        self.assertFalse(self.args.out.exists())

    def test_live_guest_fatal_is_sticky_even_if_console_later_clears(self):
        code, _, checks = self.exercise(runner.gate.TerminalError("terminal guest error"), {"status": "PASS"})
        self.assertEqual(code, 2)
        self.assertEqual(checks, [{}])
        result = json.loads((self.args.out / "result.json").read_text())
        self.assertIn("terminal guest error", result["reason"])
        self.assertTrue((self.args.out / "stop.request").exists())

    def test_transient_live_fat_read_can_still_pass_closed_check(self):
        code, _, checks = self.exercise(ValueError("transient live FAT geometry"), {"status": "PASS"})
        self.assertEqual(code, 0)
        self.assertEqual(checks, [{}, {"stopped": True, "returncode": 0}])

    def test_live_group_after_wait_cannot_qualify_closed_disk(self):
        code, processes, checks = self.exercise({"status": "PENDING"}, {"status": "PASS"}, group_present=True)
        self.assertEqual(code, 2)
        self.assertGreater(processes[0].waits, 0)
        self.assertFalse(any(check.get("stopped") for check in checks))
        result = json.loads((self.args.out / "result.json").read_text())
        self.assertFalse(result["process_group_absent_after_wait"])
        self.assertIn("process group remains", result["reason"])

    def test_inherited_optional_trace_paths_never_reach_private_child(self):
        original = runner.gate.digest(self.disk)
        dangerous = {"VEN_PCTRACE": str(self.disk), "VEN_PCTRACE_START": "0",
                     "VEN_PROFILE_CODE_EIP": "0", "VEN_EXTRA_HOOK": str(self.disk),
                     "AO486_EXTRA_HOOK": str(self.disk), "AO486_BIOS_DIR": str(self.disk),
                     "AO486_RTC_EPOCH": "0", "VTM_EXTRA_HOOK": str(self.disk), "FPGA_DDR": "0"}
        with patch.dict(os.environ, dangerous):
            code, processes, _ = self.exercise({"status": "PENDING"}, {"status": "PASS"})
        self.assertEqual(code, 0)
        self.assertEqual(runner.gate.digest(self.disk), original)
        environment = processes[0].environment
        self.assertEqual({key for key in environment if key.startswith(("VEN_", "AO486_", "VTM_"))},
                         {"AO486_BIOS_DIR", "AO486_RTC_EPOCH"})
        self.assertEqual(environment["AO486_BIOS_DIR"], str(self.args.out / "rom"))
        self.assertEqual(environment["AO486_RTC_EPOCH"], "1789257600")
        self.assertEqual(environment["FPGA_DDR"], "2")

    def test_collector_error_cannot_be_cleared_by_final_pass(self):
        with patch.object(runner.CapturedLog, "_write", side_effect=OSError(errno.ENOSPC, "no space")):
            code, _, checks = self.exercise({"status": "PENDING"}, {"status": "PASS"})
        self.assertEqual(code, 2)
        self.assertFalse(any(check.get("stopped") for check in checks))
        result = json.loads((self.args.out / "result.json").read_text())
        self.assertIn("no space", result["reason"])
        self.assertIsNotNone(result["log_capture"]["sticky_error"])

    def test_file_changed_during_final_check_cannot_leave_pass(self):
        # The existing exercise records actual wait before delegating to this
        # return object; mutate from the returned mapping's status lookup.
        class MutatingResult(dict):
            def __getitem__(inner, key):
                if key == "status":
                    path = self.args.out / "run.log"
                    path.write_bytes(b"X" * path.stat().st_size)
                return super().__getitem__(key)

        code, _, _ = self.exercise({"status": "PENDING"}, MutatingResult(status="PASS"))
        self.assertEqual(code, 2)
        result = json.loads((self.args.out / "result.json").read_text())
        self.assertIn("content changed", result["reason"])

    def test_thread_start_failure_still_waits_and_closes_pipe(self):
        with patch.object(runner.threading.Thread, "start", side_effect=RuntimeError("fixture no thread")):
            code, processes, checks = self.exercise({"status": "PENDING"}, {"status": "PASS"})
        self.assertEqual(code, 2)
        self.assertTrue(processes[0].stdout.closed)
        self.assertGreater(processes[0].waits, 0)
        self.assertEqual(checks, [])
        result = json.loads((self.args.out / "result.json").read_text())
        self.assertIn("not started", result["reason"])

    def test_early_eof_has_short_grace_not_whole_run_bound(self):
        original_popen = subprocess.Popen
        processes = []

        def spawn(command, **kwargs):
            process = original_popen([sys.executable, "-B", "-c",
                "import os,time;os.close(1);os.close(2);time.sleep(.2)"], **kwargs)
            processes.append(process)
            return process

        def stage(command, **kwargs):
            runner.shutil.copy2(command[-2], command[-1])
            return subprocess.CompletedProcess(command, 0)

        started = time.monotonic()
        with patch.object(runner.subprocess, "Popen", side_effect=spawn), \
                patch.object(runner.subprocess, "run", side_effect=stage), \
                patch.object(runner.gate, "baseline", return_value={"clean": True}), \
                patch.object(runner.gate, "check", return_value={"status": "PASS"}) as check, \
                patch.object(runner, "PIPE_EXIT_GRACE", .01), \
                contextlib.redirect_stdout(io.StringIO()):
            code = runner.run(self.args)
        self.assertEqual(code, 2)
        self.assertLess(time.monotonic() - started, 2)
        self.assertTrue(processes[0].stdout.closed)
        self.assertEqual(processes[0].returncode, 0)
        self.assertFalse(any(call.kwargs.get("stopped") for call in check.call_args_list))
        with self.assertRaises(ChildProcessError):
            os.waitpid(processes[0].pid, os.WNOHANG)
        result = json.loads((self.args.out / "result.json").read_text())
        self.assertIn("EOF before", result["reason"])


class CollectorTests(unittest.TestCase):
    """Only tiny host Python writers execute, never a simulator or guest."""

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ventium-quake-capture-test.")
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.pairs = []
        self.extra_fds = []
        self.addCleanup(self.cleanup_children)

    def cleanup_children(self):
        for fd in self.extra_fds:
            os.close(fd)
        for capture, process in self.pairs:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)
            capture.close()
            if process.stdout is not None:
                self.assertTrue(process.stdout.closed)
            with self.assertRaises(ChildProcessError):
                os.waitpid(process.pid, os.WNOHANG)

    def spawn(self, code, *, limit=1024 * 1024, retain_pipe_writer=False, pipe_wrapper=None):
        capture = runner.CapturedLog(self.base / f"log-{len(self.pairs)}", limit=limit)
        if retain_pipe_writer:
            read_fd, write_fd = os.pipe()
            self.extra_fds.append(write_fd)
            pipe = os.fdopen(read_fd, "rb", buffering=0)
            process = subprocess.Popen([sys.executable, "-B", "-c", code], stdin=subprocess.DEVNULL,
                stdout=write_fd, stderr=subprocess.STDOUT, start_new_session=True)
        else:
            process = subprocess.Popen([sys.executable, "-B", "-c", code], stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0, start_new_session=True)
            pipe = process.stdout
        self.pairs.append((capture, process))
        if pipe_wrapper:
            pipe = pipe_wrapper(pipe)
        capture.start(pipe)
        return capture, process

    def until(self, predicate):
        deadline = time.monotonic() + 3
        while not predicate():
            self.assertLess(time.monotonic(), deadline, "host fixture did not make progress")
            time.sleep(0.005)

    def finished(self, capture, process):
        rc = process.wait(timeout=3)
        data = capture.finish(timeout=1)
        self.assertTrue(capture.eof)
        self.assertEqual(capture.captured, capture.written)
        self.assertEqual(hashlib.sha256(data).hexdigest(), capture.sha.hexdigest())
        return rc, data

    def test_exact_limit_and_merged_stderr(self):
        capture, process = self.spawn("import os;os.write(1,b'ab');os.write(2,b'12');os.write(1,b'cd')", limit=6)
        self.assertEqual(self.finished(capture, process), (0, b"ab12cd"))
        self.assertEqual(capture.path.stat().st_mode & 0o777, 0o600)

    def test_many_chunks_continuously_drain_while_main_waits(self):
        capture, process = self.spawn("import os;[os.write(1,b'x'*4096) for _ in range(128)]")
        self.assertEqual(self.finished(capture, process), (0, b"x" * (128 * 4096)))

    def test_nonzero_exit_remains_visible_to_caller(self):
        capture, process = self.spawn("import os,sys;os.write(1,b'out');sys.exit(7)")
        self.assertEqual(self.finished(capture, process), (7, b"out"))

    def test_split_error_tail_is_preserved_for_checker(self):
        capture, process = self.spawn("import os,time;os.write(1,b'%Er');time.sleep(.02);os.write(2,b'ror: bad\\n')")
        _, data = self.finished(capture, process)
        self.assertRegex(data, runner.gate.ENGINE_ERROR_RE)

    def test_short_writes_and_interrupted_write_recover_exactly(self):
        original = os.write
        calls = 0

        def short(fd, data):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise InterruptedError()
            return original(fd, data[:2])

        with patch.object(runner.os, "write", side_effect=short):
            capture, process = self.spawn("import os;os.write(1,b'abcdefghij')")
            self.assertEqual(self.finished(capture, process), (0, b"abcdefghij"))
        self.assertGreaterEqual(calls, 6)

    def test_enospc_write_is_sticky_and_actual_child_is_reaped(self):
        with patch.object(runner.os, "write", side_effect=OSError(errno.ENOSPC, "fixture no space")):
            capture, process = self.spawn("import os;os.write(1,b'abc')")
            process.wait(timeout=3)
            with self.assertRaisesRegex(ValueError, "fixture no space"):
                capture.finish(timeout=1)
        self.assertEqual(capture.captured, 3)
        self.assertEqual(capture.written, 0)

    def test_zero_write_is_sticky(self):
        with patch.object(runner.os, "write", return_value=0):
            capture, process = self.spawn("import os;os.write(1,b'abc')")
            process.wait(timeout=3)
            with self.assertRaisesRegex(ValueError, "no valid progress"):
                capture.finish(timeout=1)

    def test_pipe_close_error_is_sticky_and_finish_event_is_set(self):
        class CloseFailure:
            def __init__(inner, pipe):
                inner.pipe = pipe

            def fileno(inner):
                return inner.pipe.fileno()

            def close(inner):
                inner.pipe.close()
                raise OSError(errno.EIO, "fixture close error")

        capture, process = self.spawn("import os;os.write(1,b'abc')", pipe_wrapper=CloseFailure)
        process.wait(timeout=3)
        with self.assertRaisesRegex(ValueError, "pipe close failed"):
            capture.finish(timeout=1)
        self.assertTrue(capture.finished.is_set())
        self.assertTrue(process.stdout.closed)

    def test_overflow_is_bounded_and_unqualified(self):
        capture, process = self.spawn("import os;os.write(1,b'abcdef')", limit=5)
        process.wait(timeout=3)
        with self.assertRaisesRegex(ValueError, "exceeded"):
            capture.finish(timeout=1)
        self.assertLessEqual(capture.path.stat().st_size, 5)
        self.assertEqual(capture.captured, 6)

    def test_read_error_is_sticky(self):
        original = os.read

        def failed(fd, count):
            if any(pair[0].pipe.fileno() == fd for pair in self.pairs if not pair[0].pipe.closed):
                raise OSError(errno.EIO, "fixture pipe read error")
            return original(fd, count)

        with patch.object(runner.os, "read", side_effect=failed):
            capture, process = self.spawn("import os;os.write(1,b'abc')")
            process.wait(timeout=3)
            with self.assertRaisesRegex(ValueError, "pipe read error"):
                capture.finish(timeout=1)

    def test_fsync_error_is_sticky(self):
        capture, process = self.spawn("import os;os.write(1,b'abc')")
        process.wait(timeout=3)
        with patch.object(runner.os, "fsync", side_effect=OSError(errno.ENOSPC, "fixture flush error")):
            with self.assertRaisesRegex(OSError, "flush error"):
                capture.finish(timeout=1)
        with self.assertRaisesRegex(ValueError, "flush error"):
            capture.snapshot()

    def test_truncation_before_tail_cannot_qualify(self):
        capture, process = self.spawn("import os,time;os.write(1,b'abc');time.sleep(.1);os.write(1,b'tail')")
        self.until(lambda: capture.written == 3)
        os.truncate(capture.path, 0)
        process.wait(timeout=3)
        with self.assertRaisesRegex(ValueError, "truncated"):
            capture.finish(timeout=1)

    def test_same_size_rewrite_is_detected_by_capture_hash(self):
        capture, process = self.spawn("import os;os.write(1,b'abc')")
        process.wait(timeout=3)
        self.until(lambda: capture.finished.is_set())
        capture.path.write_bytes(b"xyz")
        with self.assertRaisesRegex(ValueError, "content changed"):
            capture.finish(timeout=1)

    def test_restoring_file_after_detected_error_cannot_clear_it(self):
        capture, process = self.spawn("import os;os.write(1,b'abc')")
        process.wait(timeout=3)
        self.until(lambda: capture.finished.is_set())
        capture.path.write_bytes(b"xyz")
        with self.assertRaisesRegex(ValueError, "content changed"):
            capture.snapshot()
        capture.path.write_bytes(b"abc")
        with self.assertRaisesRegex(ValueError, "content changed"):
            capture.finish(timeout=1)

    def test_symlink_replacement_does_not_write_foreign_file(self):
        capture, process = self.spawn("import os,time;os.write(1,b'abc');time.sleep(.1);os.write(1,b'tail')")
        self.until(lambda: capture.written == 3)
        foreign = self.base / "foreign"
        foreign.write_bytes(b"precious")
        capture.path.rename(self.base / "owned-moved")
        capture.path.symlink_to(foreign)
        process.wait(timeout=3)
        with self.assertRaisesRegex(ValueError, "identity changed"):
            capture.finish(timeout=1)
        self.assertEqual(foreign.read_bytes(), b"precious")

    def test_hardlink_is_rejected(self):
        capture, process = self.spawn("import os;os.write(1,b'abc')")
        process.wait(timeout=3)
        self.until(lambda: capture.finished.is_set())
        os.link(capture.path, self.base / "second-name")
        with self.assertRaisesRegex(ValueError, "identity changed"):
            capture.finish(timeout=1)

    def test_existing_or_symlink_log_is_refused_without_mutation(self):
        target = self.base / "existing"
        target.write_bytes(b"precious")
        for path in (target, self.base / "link"):
            if path != target:
                path.symlink_to(target)
            with self.subTest(path=path), self.assertRaises(FileExistsError):
                runner.CapturedLog(path)
        self.assertEqual(target.read_bytes(), b"precious")

    def test_actual_child_exit_without_eof_is_not_complete(self):
        capture, process = self.spawn("import os;os.write(1,b'abc')", retain_pipe_writer=True)
        self.assertEqual(process.wait(timeout=3), 0)
        with self.assertRaisesRegex(ValueError, "EOF missing"):
            capture.finish(timeout=.05)
        self.assertFalse(capture.eof)

    def test_eof_does_not_mean_child_exited(self):
        capture, process = self.spawn("import os,time;os.close(1);os.close(2);time.sleep(.1)")
        self.until(lambda: capture.eof)
        self.assertIsNone(process.poll())
        self.assertEqual(self.finished(capture, process), (0, b""))


class SourceArchiveTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ventium-quake-source-test.")
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)

    def test_observed_sources_are_archived_and_loaded_code_is_identified(self):
        provenance = runner.archive_python_sources(self.base)
        runner.close_python_sources(provenance)
        self.assertIn("not exact loaded-source proof", provenance["provenance"])
        self.assertEqual(len(provenance["sources"]), 2)
        self.assertEqual(provenance["loaded_function_code_before"], provenance["loaded_function_code_after"])
        for source in provenance["sources"].values():
            self.assertTrue(source["canonical_source_unchanged"])
            self.assertEqual(Path(source["archive"]).stat().st_mode & 0o777, 0o400)

    def test_source_archive_mutation_is_rejected(self):
        provenance = runner.archive_python_sources(self.base)
        archive = Path(next(iter(provenance["sources"].values()))["archive"])
        archive.chmod(0o600)
        archive.write_bytes(b"replaced source archive")
        with self.assertRaisesRegex(ValueError, "archive identity/content changed"):
            runner.close_python_sources(provenance)

    def test_canonical_source_changes_are_observed_not_mislabelled_execution(self):
        provenance = runner.archive_python_sources(self.base)
        source = next(iter(provenance["sources"].values()))
        changed = self.base / "mutable-canonical-fixture.py"
        changed.write_bytes(b"different source text; never executed")
        source["source"] = str(changed)
        runner.close_python_sources(provenance)
        self.assertFalse(source["canonical_source_unchanged"])
        self.assertEqual(source["archive_sha256_after"], source["sha256_before"])

    def test_loaded_checker_function_change_is_rejected(self):
        provenance = runner.archive_python_sources(self.base)
        with patch.object(runner.gate, "check", lambda *a, **k: {"status": "PASS"}):
            with self.assertRaisesRegex(ValueError, "loaded runner/checker function code changed"):
                runner.close_python_sources(provenance)


if __name__ == "__main__":
    limit = 512 * 1024 * 1024
    soft, hard = resource.getrlimit(resource.RLIMIT_AS)
    resource.setrlimit(resource.RLIMIT_AS, (min(limit, soft) if soft >= 0 else limit, hard))
    unittest.main(verbosity=2)
