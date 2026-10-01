#!/usr/bin/env python3
"""Small acceptance-classification gate; no simulator or disk writes."""
from pathlib import Path
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_win95_ablation as runner
from run_win95_ablation import ERROR, final_status, terminal_error


class Win95ScreenTest(unittest.TestCase):
    def test_boot_errors_and_engine_errors_are_terminal(self):
        for message in (ERROR, "Windows protection error", "%Error: ASSERT",
                        "Assertion failed", "SNAPSHOT-ERROR: truncated state",
                        "terminate called", "Segmentation fault"):
            with self.subTest(message=message):
                error = terminal_error(message.encode())
                self.assertIsNotNone(error)
                self.assertIn(final_status(0, error), ("vxd_error", "terminal_error"))

    def test_case_and_read_boundary_carry(self):
        text = b"  |WINDOWS PROTECTION ERROR\n"
        for cut in range(len(text)):
            carry, new = text[:cut][-256:], text[cut:]
            self.assertIsNotNone(terminal_error(carry + new))

    def test_architectural_faults_and_loading_are_not_terminal(self):
        for output in (b"[FAULT] vec=6 err=00000000", b"[GP] delivered #GP to VMM",
                       b"Starting Windows 95...", b"[HOST-STOP] not a benchmark pass"):
            self.assertIsNone(terminal_error(output))

    def test_zero_exit_without_desktop_never_passes(self):
        self.assertEqual(final_status(0, None), "clean_exit_unqualified")
        self.assertEqual(final_status(-15, None), "terminated")
        self.assertEqual(final_status(2, None), "sim_error")

    def test_write_drop_diagnostic_is_removed(self):
        source = (Path(__file__).parent / "run_win95_ablation.py").read_text()
        self.assertIn('environment.pop("VEN_IDE_DROP_WRITES", None)', source)


class Win95CaptureTest(unittest.TestCase):
    """Real tiny host writers only; no simulator executable/disk is launched."""

    NORMAL = (b'>>> ventium-soc: reset released; running up to 1000 cycles\n'
              b'>>> done: cyc=100 retires=50 last cs=0010:eip=00001000\n')

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='ventium-win95-capture-test.', dir='/tmp')
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name)
        self.disk = self.base/'source.vhd'; self.disk.write_bytes(b'unchanged host fixture')
        self.binary = self.base/'never-executed-simulator'; self.binary.write_bytes(b'fixture only')
        self.rom = self.base/'rom'; self.rom.mkdir()
        for name in ('boot0.rom', 'boot1.rom'):
            (self.rom/name).write_bytes(name.encode())
        self.args = SimpleNamespace(out=self.base/'run', disk=self.disk, extra_binary=self.binary,
            select=None, cpus=[min(os.sched_getaffinity(0))], bios_dir=self.rom, cycles=1000,
            rate=45000000, rtc_rate=45000000, rtc_epoch=1789257600, fpga_ddr=2,
            kb=None, kb_start=25000000, kb_gap=500000, fb_every=0,
            vga_div=None, vga_jit=None, ao486_original=False, sim_extra=[])

    def exercise(self, code, extra=()):
        original_popen, original_sleep = subprocess.Popen, time.sleep
        processes = []
        def spawn(command, **kwargs):
            self.assertEqual(kwargs['stdout'], subprocess.PIPE)
            self.assertTrue(kwargs['start_new_session'])
            process = original_popen([sys.executable, '-B', '-c', code], **kwargs)
            processes.append(process)
            return process
        def stage(command, **kwargs):
            runner.shutil.copy2(command[-2], command[-1])
            return subprocess.CompletedProcess(command, 0)
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(runner, 'binaries', return_value=[]))
            stack.enter_context(patch.object(runner.subprocess, 'Popen', side_effect=spawn))
            stack.enter_context(patch.object(runner.subprocess, 'run', side_effect=stage))
            stack.enter_context(patch.object(runner.time, 'sleep', side_effect=lambda duration: original_sleep(min(.01, duration))))
            stack.enter_context(patch.object(runner.evidence, 'PIPE_EXIT_GRACE', .01))
            for context in extra:
                stack.enter_context(context)
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            runner.launch(self.args)
        for process in processes:
            self.assertIsNotNone(process.returncode)
            self.assertTrue(process.stdout.closed)
            with self.assertRaises(ChildProcessError):
                os.waitpid(process.pid, os.WNOHANG)
        directory = self.args.out/('external__'+self.binary.name)
        return json.loads((directory/'result.json').read_text()), directory

    def normal_code(self):
        return 'import os;os.write(1,'+repr(self.NORMAL)+')'

    def test_normal_closure_is_still_not_desktop_pass(self):
        result, directory = self.exercise(self.normal_code())
        self.assertEqual(result['status'], 'clean_exit_unqualified')
        self.assertTrue(result['actual_child_wait'])
        self.assertTrue(result['process_group_absent_after_wait'])
        self.assertTrue(result['log_capture']['pipe_eof'])
        self.assertEqual(result['log_capture']['captured_bytes'], len(self.NORMAL))
        self.assertEqual((directory/'run.log').read_bytes(), self.NORMAL)
        self.assertTrue(result['input_and_observed_source_hashes_unchanged'])
        self.assertFalse(result['desktop_acceptance'])

    def test_collection_failure_is_sticky_and_reaped(self):
        with patch.object(runner.evidence.CapturedLog, '_write', side_effect=OSError('fixture log write failed')):
            result, directory = self.exercise(self.normal_code())
        self.assertEqual(result['status'], 'evidence_error')
        self.assertIn('fixture log write failed', result['evidence_error'])
        self.assertTrue((directory/'run.log').exists())
        self.assertTrue(result['actual_child_wait'])

    def test_thread_start_failure_still_waits_and_closes(self):
        result, _ = self.exercise(self.normal_code(),
            [patch.object(runner.evidence.threading.Thread, 'start', side_effect=RuntimeError('fixture no thread'))])
        self.assertEqual(result['status'], 'evidence_error')
        self.assertTrue(result['actual_child_wait'])
        self.assertFalse(result['log_capture']['pipe_eof'])

    def test_early_EOF_does_not_wait_for_run_cap(self):
        began = time.monotonic()
        result, _ = self.exercise('import os,time;os.close(1);os.close(2);time.sleep(.3)')
        self.assertEqual(result['status'], 'evidence_error')
        self.assertIn('EOF before simulator exit', result['evidence_error'])
        self.assertLess(time.monotonic()-began, 2)

    def test_missing_final_footer_is_unqualified_evidence_error(self):
        result, _ = self.exercise('print("ordinary incomplete host output")')
        self.assertEqual(result['status'], 'evidence_error')
        self.assertIn('normal final report', result['evidence_error'])

    def test_terminal_failure_remains_terminal(self):
        result, _ = self.exercise('print("Windows protection error")')
        self.assertEqual(result['status'], 'terminal_error')
        self.assertFalse(result['desktop_acceptance'])


if __name__ == "__main__":
    unittest.main()
