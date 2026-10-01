#!/usr/bin/env python3
"""Tiny synthetic host fixtures; never launch a guest/model or system service."""
import copy
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import check_coremark_standard_closed as gate


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class ClosedCoreMarkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ventium-cm-closed-host.")
        # TMPDIR may be a repository/external symlink. Real launchers resolve
        # their output base before serializing argv; fixtures must do likewise.
        self.root = Path(self.temp.name).resolve()
        self.run = self.root / "run"
        self.run.mkdir()
        self.matrix = self.run / "ventium-coremark-matrix.host"
        self.matrix.mkdir()
        self.pid, self.unit, self.inv = 90000001, "ventium-host-coremark.service", "a" * 32
        binary, record, header, snapshot, driver = [self.root / name for name in
                                                   ("tb_ventium", "Vventium_top__verFiles.dat", "Vventium_top.h", "model_input_snapshot.h", "driver.py")]
        for path in (binary, record, header, driver):
            path.write_bytes((path.name + " frozen host fixture\n").encode())
        snapshot.write_text("// Complete generated model-header SHA256: " + sha(header) + "\n")
        (self.run / "run.py").write_text("# frozen launcher fixture\n")
        (self.run / "observed-driver.py").write_bytes(driver.read_bytes())
        images = {seed: self.root / (seed + ".image.json") for seed in gate.CRCS}
        for seed, path in images.items():
            path.write_text(json.dumps({"host_fixture": seed}))
        pins = {str(path): sha(path) for path in (binary, record, header, snapshot, driver, *images.values())}
        self.expect = {"unit": self.unit, "invocation_id": self.inv, "affinity": [10, 11], "pins": pins,
                       "driver_path": str(driver), "launcher_sha256": sha(self.run / "run.py")}
        profile = {"binary": str(binary), "sha256": pins[str(binary)], "compile_record": str(record),
                   "compile_record_sha256": pins[str(record)], "model_threads": 1, "input_snapshot_capable": True,
                   "input_snapshot_generated_headers": {str(header): pins[str(header)], str(snapshot): pins[str(snapshot)]}}
        case = {"label": "candidate", "binary": str(binary), "model_threads": 1, "memory_backend": "direct",
                "clock_cycle_probe": True, "clock_cycle_probe_nr": 403, "clock_cycle_probe_clock_id": 0,
                "skip_unchanged_settle": True}
        workloads = [{"label": seed + "1500", "seed": seed, "iterations": 1500, "image": str(images[seed]),
                      "crcfinal": gate.CRCS[seed]["crcfinal"], "max_insn": 700000000,
                      "max_cycles": 900000000, "timeout_seconds": 3600} for seed in gate.CRCS]
        plan = {"version": 1, "cases": [case], "workloads": workloads}
        self.write(self.run / "plan.json", plan)
        self.expect["plan_sha256"] = sha(self.run / "plan.json")
        loaded = copy.deepcopy(plan)
        loaded["cases"][0]["profile"] = profile
        for w in loaded["workloads"]:
            w["image_sha256"] = pins[w["image"]]
        self.write(self.matrix / "plan.json", loaded)
        limits = {"memory.max": str(2 * 1024**3), "memory.swap.max": "0", "pids.max": "160", "cpu.max": "200000 100000",
                  "memory.events": "oom 0\noom_kill 0\noom_group_kill 0", "memory.events.local": "oom 0\noom_kill 0\noom_group_kill 0",
                  "cgroup.procs": str(self.pid)}
        before = {"pid": self.pid, "unix": 100, "exe_sha256": "b" * 64, "cgroup": "/sys/fs/cgroup/" + self.unit,
                  "affinity": [10, 11], "invocation_id": self.inv, "observed_sha256": pins, "cgroup_files": limits}
        final = dict(copy.deepcopy(before), unix=200, matrix_returncode=0, pins_unchanged=True, oom_events_zero=True, all_native_children_gone=True)
        self.write(self.run / "receipt-before.json", before)
        self.write(self.run / "receipt-final.json", final)
        self.write(self.run / "launcher-pin.json", {"launcher_sha256": self.expect["launcher_sha256"],
                   "plan_sha256": self.expect["plan_sha256"], "loaded_driver_sha256": pins[str(driver)]})
        natives = []
        for index, workload in enumerate(loaded["workloads"]):
            seed, cpu, native_pid = workload["seed"], 10 + index, self.pid + index + 1
            job = self.matrix / (case["label"] + "--" + workload["label"])
            job.mkdir()
            argv = ["taskset", "--cpu-list", str(cpu), str(binary), "--quake-image", workload["image"], "--emulate-syscalls", "--no-trace", "--cycle", "--max-insn", "700000000", "--max-cycles", "900000000", "--quiesce", "200000", "--user-stdout", str(job / "guest.stdout"), "--skip-unchanged-settle"]
            self.write(job / "manifest.json", {"case": loaded["cases"][0], "workload": workload, "cpus": [cpu], "argv": argv,
                      "started_unix": 110, "environment_overrides": {"TB_CLOCK_CYCLE_PROBE": "1"}, "expected_clock_probe": {"nr": 403, "clock_id": 0}})
            guest, log = self.raw(seed)
            (job / "guest.stdout").write_text(guest)
            (job / "run.log").write_text(log)
            result = {"returncode": 0, "wall_seconds": 50, "retired": 50000000, "clocks": (1 << 26) + 100, "crc": gate.CRCS[seed]}
            result.update({key: True for key in ("complete", "crc_ok", "iterations_ok", "dataset_ok", "coremark_report_validated", "guest_duration_ok", "binary_unchanged", "image_unchanged", "compile_record_unchanged", "generated_headers_unchanged", "input_settle_reconciles", "clock_window_valid", "score_eligible")})
            self.write(job / "result.json", result)
            natives.append({"workload": workload["label"], "pid": native_pid, "parent_pid": self.pid, "actual_affinity": [cpu],
                            "actual_exe": str(binary), "actual_proc_exe_sha256": pins[str(binary)], "session_id": native_pid,
                            "process_group": native_pid, "starttime_ticks": 123})
        self.write(self.run / "receipt-native-live.json", {"unit": self.unit, "invocation_id": self.inv, "main_pid": self.pid, "native_processes": natives})
        self.supervisor = {"unit": self.unit, "invocation_id": self.inv,
                           "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                           "ActiveState": "inactive", "SubState": "dead", "MainPID": "0", "Result": "success",
                           "ExecMainCode": "1", "ExecMainStatus": "0", "ControlGroup": "/" + self.unit}

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def write(path, value):
        Path(path).write_text(json.dumps(value, sort_keys=True))

    @staticmethod
    def raw(seed):
        guest = (f"2K {seed} run parameters for coremark.\nCoreMark Size    : 666\nTotal time (secs): 10.500000\nIterations       : 1500\n" +
                 "".join(f"{field}: 0x{value}\n" for field, value in gate.CRCS[seed].items()) +
                 "Correct operation validated. See README.md for run and reporting rules.\n" +
                 ("CoreMark 1.0 : 142.8 / host fixture / Heap\n" if seed == "performance" else ""))
        clocks = (1 << 26) + 100
        log = ("[clock-cycle] n=10 nr=403 clock_id=0 cycle=20\n" +
               f"tb: progress @cycle {1 << 26} retired 49999900 vga_nz 0\n" +
               f"[clock-cycle] n=49999990 nr=403 clock_id=0 cycle={clocks - 1}\n" +
               f"tb: stop: FREE-RUN guest exit_group(0) after 50000000 retired in {clocks} clocks\n" +
               f"[input-settle] ports=18 cells=18 mandatory_edge_evals={2 * clocks} full_settle_evals=100 skipped_settle_evals={2 * clocks - 100}\n" +
               f"tb: retired 50000000 instructions in {clocks} clocks (bus: 100 reads, 100 writes)\n" +
               f"tb: FREE-RUN: 28 syscalls emulated, {len(guest.encode())} bytes stdout captured\n----- guest stdout -----\n{guest}------------------------\n")
        return guest, log

    def mutate(self, path, edit):
        value = json.loads(path.read_text())
        edit(value)
        self.write(path, value)

    def qualify(self):
        return gate.check(self.run, self.expect, supervisor=self.supervisor)

    def test_complete_two_seed_observed_evidence(self):
        result = self.qualify()
        self.assertEqual(result["status"], "PASS")
        self.assertEqual({x["seed"] for x in result["seeds"]}, set(gate.CRCS))
        self.assertIn("not lossless", result["limitations"][0])

    def test_live_missing_final_receipt_fails(self):
        (self.run / "receipt-final.json").unlink()
        with self.assertRaises(OSError):
            self.qualify()

    def test_supervisor_live_unknown_or_failed_wait(self):
        for key, bad in (("ActiveState", "active"), ("SubState", "running"), ("MainPID", "1"),
                         ("invocation_id", ""), ("boot_id", "wrong"), ("ExecMainCode", "0"),
                         ("ExecMainStatus", "1"), ("Result", "oom-kill"), ("ControlGroup", "/wrong")):
            with self.subTest(key=key):
                saved = self.supervisor[key]
                self.supervisor[key] = bad
                with self.assertRaises(ValueError):
                    self.qualify()
                self.supervisor[key] = saved

    def test_oom_missing_unlimited_or_child_alive(self):
        path = self.run / "receipt-final.json"
        saved = json.loads(path.read_text())
        for key, bad in (("memory.events", "oom 0\noom_kill 1\noom_group_kill 0"),
                         ("memory.events.local", "oom 0"), ("memory.events", "oom 0\noom 0\noom_kill 0\noom_group_kill 0"),
                         ("memory.max", "max"), ("memory.swap.max", "1"), ("pids.max", "161"),
                         ("cpu.max", "max 100000"), ("cpu.max", "200001 100000"),
                         ("cgroup.procs", str(self.pid) + "\n2")):
            with self.subTest(key=key, bad=bad):
                value = copy.deepcopy(saved)
                value["cgroup_files"][key] = bad
                self.write(path, value)
                with self.assertRaises(ValueError):
                    self.qualify()
        self.write(path, saved)

    def test_timeout_interruption_failure_or_nonzero_wait(self):
        path = self.matrix / "candidate--performance1500/result.json"
        saved = json.loads(path.read_text())
        for key, bad in (("timed_out", True), ("interrupted", True), ("failure", "oops"), ("returncode", 1), ("returncode", False)):
            with self.subTest(key=key):
                self.write(path, dict(saved, **{key: bad}))
                with self.assertRaises(ValueError):
                    self.qualify()
        self.write(path, saved)

    def test_changed_launcher_archive_input_and_header(self):
        paths = [self.run / "run.py", self.run / "observed-driver.py", *(Path(p) for p in self.expect["pins"] if p != self.expect["driver_path"])]
        for path in paths:
            with self.subTest(path=path):
                saved = path.read_bytes()
                path.write_bytes(saved + b"changed\n")
                with self.assertRaises(ValueError):
                    self.qualify()
                path.write_bytes(saved)

    def test_historical_archived_driver_not_mutable_canonical(self):
        Path(self.expect["driver_path"]).write_text("# a later canonical repair\n")
        self.assertEqual(self.qualify()["status"], "PASS")

    def test_actual_supervisor_query_unknown_or_wrong_group(self):
        with patch.object(gate, "query_supervisor", return_value=self.supervisor):
            self.assertEqual(gate.check(self.run, self.expect)["status"], "PASS")
        with patch.object(gate, "query_supervisor", return_value=dict(self.supervisor, ControlGroup="")):
            self.assertEqual(gate.check(self.run, self.expect)["status"], "PASS")
        for bad in (dict(self.supervisor, invocation_id=""), dict(self.supervisor, ControlGroup="/wrong")):
            with self.subTest(bad=bad):
                with patch.object(gate, "query_supervisor", return_value=bad):
                    with self.assertRaises(ValueError):
                        gate.check(self.run, self.expect)

    def test_external_closure_receipt_requires_reviewed_digest(self):
        expected_path, closure = self.root / "expect.json", self.root / "closure.json"
        self.write(expected_path, self.expect)
        self.write(closure, self.supervisor)
        argv = ["checker", str(self.run), "--expect", str(expected_path), "--expect-sha256", sha(expected_path),
                "--supervisor-closure", str(closure)]
        for suffix in ([], ["--supervisor-sha256", "0" * 64]):
            with self.subTest(suffix=suffix), patch("sys.argv", argv + suffix), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:
                    gate.main()
                self.assertEqual(caught.exception.code, 2)
        with patch("sys.argv", argv + ["--supervisor-sha256", sha(closure)]), redirect_stdout(io.StringIO()):
            self.assertEqual(gate.main(), 0)

    def test_missing_or_mutated_second_seed(self):
        path = self.matrix / "candidate--validation1500/result.json"
        path.rename(path.with_suffix(".saved"))
        with self.assertRaises(OSError):
            self.qualify()
        path.with_suffix(".saved").rename(path)
        self.mutate(self.matrix / "plan.json", lambda x: x["workloads"][1].update(seed="performance"))
        with self.assertRaises(ValueError):
            self.qualify()

    def test_raw_falsegreen_report_mutations(self):
        guest, log = self.raw("performance")
        for original, bad in (("666", "667"), ("1500", "10"), ("10.500000", "0.500000"),
                              ("e714", "e715"), ("Correct operation validated.", "ERROR! Correct operation validated.")):
            with self.subTest(original=original):
                changed = guest.replace(original, bad)
                changed_log = log.replace(guest, changed).replace(f"{len(guest.encode())} bytes stdout", f"{len(changed.encode())} bytes stdout")
                with self.assertRaises(ValueError):
                    gate.report(changed_log.encode(), changed.encode(), "performance")
        with self.assertRaises(ValueError):
            gate.report(log.replace("seedcrc: 0xe9f5", "seedcrc: 0xe9f5\nseedcrc: 0xe9f5").encode(),
                        (guest + "seedcrc: 0xe9f5\n").encode(), "performance")

    def test_truncated_changed_or_ambiguous_native_footers(self):
        guest, log = self.raw("performance")
        changes = [log[:-1], log.replace("------------------------\n", ""),
                   log.replace("tb: progress @cycle 67108864 retired 49999900 vga_nz 0\n", ""),
                   log.replace("full_settle_evals=100", "full_settle_evals=101"),
                   log.replace("tb: retired 50000000", "tb: retired 50000001"),
                   log.replace("----- guest stdout -----", "----- partial stdout -----"),
                   log.replace("tb: stop:", "tb: stop: reached --max-cycles\ntb: stop:"),
                   log.replace("nr=403", "nr=265"), log + "[FAULT] vec=14\n"]
        for value in changes:
            with self.subTest(value=value[-100:]):
                with self.assertRaises(ValueError):
                    gate.report(value.encode(), guest.encode(), "performance")

    def test_duplicate_json_and_symlink_evidence(self):
        path = self.run / "receipt-final.json"
        saved = path.read_bytes()
        path.write_bytes(b'{"pid":1,"pid":2}')
        with self.assertRaises(ValueError):
            self.qualify()
        path.write_bytes(saved)
        renamed = path.with_suffix(".saved")
        path.rename(renamed)
        path.symlink_to(renamed)
        with self.assertRaises(OSError):
            self.qualify()


if __name__ == "__main__":
    unittest.main()
