#!/usr/bin/env python3
"""Host-only runner tests; no guest simulation or external disk writes."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
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
        kwargs["stdout"].write(b">>> done: cyc=500000 retires=100000 last cs=0010:eip=00010000\n")
        kwargs["stdout"].flush()

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

    def exercise(self, live, final):
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


if __name__ == "__main__":
    unittest.main()
