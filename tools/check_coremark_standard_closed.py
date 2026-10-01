#!/usr/bin/env python3
"""Independently qualify a CLOSED, pinned two-seed CoreMark matrix.

This is observed functional evidence, not retroactive lossless pipe-capture or
compiler-ancestry proof. The old matrix uses ordinary files, without sticky I/O
receipts. We require complete mutually consistent raw reports, actual recorded
native waits, final resource/child receipts and authoritative owner closure.
No guest is launched, stopped, modified or resumed by this checker.

--expect is an externally reviewed JSON object containing unit, invocation_id,
affinity, pins (absolute path -> SHA256), driver_path, launcher_sha256 and
plan_sha256. Its independently supplied --expect-sha256 binds that expectation.
If systemd has unloaded the transient unit, --supervisor-closure may contain a
root-observed receipt with those identity fields, boot_id and the exact systemd
ActiveState/SubState/MainPID/Result/ExecMainCode/ExecMainStatus/ControlGroup.
Its independently supplied --supervisor-sha256 must bind that reviewed receipt.
JSON alone is not proof of past wait: the caller owns that external authority.
An unloaded unit's default 'success' is never historical exit evidence.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import time


LIMIT = 16 * 1024 * 1024
SHA = re.compile(r"[0-9a-f]{64}\Z")
CRCS = {
    "performance": {"seedcrc": "e9f5", "crclist": "e714", "crcmatrix": "1fd7", "crcstate": "8e3a", "crcfinal": "25b5"},
    "validation": {"seedcrc": "18f2", "crclist": "e3c1", "crcmatrix": "0747", "crcstate": "8d84", "crcfinal": "e230"},
}
ERROR = re.compile(r"ERROR!|Errors detected|%Error\b|Assertion failed|\[FAULT\]|UNIMPLEMENTED|CPU HUNG|Segmentation fault|runtime error:|AddressSanitizer:", re.I)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def exact_int(value, expected=None):
    return type(value) is int and (expected is None or value == expected)


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


class Files:
    """Bounded, regular, non-symlink reads; detect changes during this audit."""
    def __init__(self):
        self.observed = {}

    def read(self, path, *, digest_only=False):
        path = Path(path)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1, "non-private/non-regular evidence file")
            require(before.st_size <= (64 * 1024 * 1024 if digest_only else LIMIT), "evidence exceeds bounded read limit")
            digest = hashlib.sha256()
            chunks = []
            total = 0
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                total += len(chunk)
                require(total <= before.st_size, "evidence grew while reading")
                digest.update(chunk)
                if not digest_only:
                    chunks.append(chunk)
            after = os.fstat(fd)
            named = path.lstat()
            identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_nlink)
            require(total == before.st_size and identity(before) == identity(after) == identity(named), "evidence changed while reading")
            key = str(path.absolute())
            observation = (identity(after), digest.hexdigest())
            require(key not in self.observed or self.observed[key] == observation, "evidence changed during audit")
            self.observed[key] = observation
            return digest.hexdigest() if digest_only else b"".join(chunks)
        finally:
            os.close(fd)

    def json(self, path):
        def bad_constant(_value):
            raise ValueError("non-finite JSON number")
        return json.loads(self.read(path), object_pairs_hook=pairs, parse_constant=bad_constant)

    def finish(self):
        for path in list(self.observed):
            self.read(path, digest_only=True)


def one(pattern, text, label):
    found = list(re.finditer(pattern, text, re.M))
    require(len(found) == 1, "missing/ambiguous " + label)
    return found[0]


def report(log_bytes, guest_bytes, seed):
    log, guest = log_bytes.decode("utf-8"), guest_bytes.decode("utf-8")
    require(log.endswith("\n") and guest.endswith("\n") and not ERROR.search(log + guest), "terminal error or truncated report")
    require(guest.startswith("2K " + seed + " run parameters for coremark.\n"), "not the standard 2000-byte seed")
    require(one(r"^CoreMark Size\s*:\s*(\d+)\s*$", guest, "dataset")[1] == "666", "wrong partitioned 2000-byte dataset")
    require(one(r"^Iterations\s*:\s*(\d+)\s*$", guest, "iterations")[1] == "1500", "wrong iterations")
    seconds = float(one(r"^Total time \(secs\)\s*:\s*([0-9.]+)\s*$", guest, "guest time")[1])
    require(math.isfinite(seconds) and seconds >= 10, "short/non-finite standard report")
    require(guest.count("Correct operation validated.") == 1, "missing/duplicate validation banner")
    # CoreMark only prints its final score banner for the performance seeds.
    require(len(re.findall(r"^CoreMark 1\.0 : .+$", guest, re.M)) == (1 if seed == "performance" else 0), "unexpected final score banner")
    crc = {}
    for line in guest.splitlines():
        if any(field in line for field in CRCS[seed]):
            match = re.fullmatch(r"(?:\[0\])?(seedcrc|crclist|crcmatrix|crcstate|crcfinal)[ \t]*:[ \t]*0x([0-9a-fA-F]{4})", line)
            require(match is not None and match[1] not in crc, "malformed/duplicate CRC")
            crc[match[1]] = match[2].lower()
    require(crc == CRCS[seed], "standard CRC mismatch")
    stop = one(r"^tb: stop: FREE-RUN guest exit_group\(0\) after (\d+) retired in (\d+) clocks$", log, "normal guest stop")
    require(log.count("tb: stop:") == 1, "extra abnormal/ambiguous stop")
    retired, clocks = map(int, stop.groups())
    require(0 < retired < 700000000 and 0 < clocks < 900000000, "invalid/exhausted final counters")
    total = one(r"^tb: retired (\d+) instructions in (\d+) clocks \(bus: (\d+) reads, (\d+) writes\)$", log, "native final statistics")
    require(tuple(map(int, total.groups()[:2])) == (retired, clocks) and total.start() > stop.end(), "final counters/order disagree")
    settle = one(r"^\[input-settle\] ports=(\d+) cells=(\d+) mandatory_edge_evals=(\d+) full_settle_evals=(\d+) skipped_settle_evals=(\d+)$", log, "input settle")
    ports, cells, mandatory, full, skipped = map(int, settle.groups())
    require(0 < ports <= cells and mandatory == full + skipped == 2 * clocks and stop.end() < settle.start() < total.start(), "incomplete input-settle statistics")
    captured = one(r"^tb: FREE-RUN: (\d+) syscalls emulated, (\d+) bytes stdout captured$", log, "native stdout count")
    require(int(captured[1]) > 0 and int(captured[2]) == len(guest_bytes) and captured.start() > total.end(), "native guest byte count/order mismatch")
    prefix, suffix = "----- guest stdout -----\n", "------------------------\n"
    require(log.count(prefix) == 1 and log.count(suffix) == 1 and log.endswith(prefix + guest + suffix), "incomplete/changed embedded guest report")
    queries = re.findall(r"^\[clock-cycle\] n=(\d+) nr=403 clock_id=0 cycle=(\d+)$", log, re.M)
    require(log.count("[clock-cycle]") == 2 and len(queries) == 2, "missing/tainted clock probes")
    start, end = [tuple(map(int, value)) for value in queries]
    require(0 <= start[0] < end[0] <= retired and 0 <= start[1] < end[1] <= clocks, "invalid clock probe order/counters")
    progress = re.findall(r"^tb: progress @cycle (\d+) retired (\d+) vga_nz 0$", log, re.M)
    require(log.count("tb: progress @cycle") == len(progress), "malformed progress")
    require([int(v[0]) for v in progress] == list(range(1 << 26, clocks, 1 << 26)), "missing/duplicate direct-loop heartbeat")
    counts = [int(v[1]) for v in progress]
    require(counts == sorted(counts) and all(0 < n <= retired for n in counts), "progress retire counters regress")
    return {"seed": seed, "crc": crc, "retired": retired, "clocks": clocks, "guest_seconds": seconds,
            "cm_per_mhz_total_program": 1500000000 / clocks, "clock_window_clocks": end[1] - start[1],
            "cm_per_mhz_clock_window": 1500000000 / (end[1] - start[1]), "progress_records": len(progress)}


def resource_receipt(receipt, expected):
    require(receipt["invocation_id"] == expected["invocation_id"] and receipt["affinity"] == expected["affinity"], "receipt identity/affinity mismatch")
    require(receipt["cgroup"].endswith("/" + expected["unit"]) and receipt["cgroup"].startswith("/sys/fs/cgroup/"), "wrong actual cgroup")
    require(exact_int(receipt["pid"]) and receipt["pid"] > 0, "invalid owner PID")
    values = receipt["cgroup_files"]
    require(values["memory.max"] == str(2 * 1024**3) and values["memory.swap.max"] == "0" and values["pids.max"] == "160", "unsafe resource caps")
    quota, period = values["cpu.max"].split()
    require(quota.isdecimal() and period.isdecimal() and 0 < int(quota) <= 2 * int(period), "unlimited/unsafe CPU cap")
    for name in ("memory.events", "memory.events.local"):
        counters = pairs([line.split() for line in values[name].splitlines()])
        require({"oom", "oom_kill", "oom_group_kill"} <= counters.keys(), "missing OOM counters")
        require(all(value.isdecimal() for value in counters.values()), "malformed OOM counter")
        require(all(counters[key] == "0" for key in ("oom", "oom_kill", "oom_group_kill")), "OOM-tainted run")
    require(values["cgroup.procs"].split() == [str(receipt["pid"])], "native children still present at owner receipt")
    require(receipt["observed_sha256"] == expected["pins"], "observed source/input pins disagree")


def query_supervisor(unit):
    properties = ("ActiveState", "SubState", "MainPID", "InvocationID", "Result", "ExecMainCode", "ExecMainStatus", "ControlGroup")
    process = subprocess.run(["systemctl", "--user", "show", unit, *["--property=" + key for key in properties]],
                             stdin=subprocess.DEVNULL, capture_output=True, timeout=5, check=True)
    require(len(process.stdout) <= 65536 and len(process.stderr) <= 65536, "unbounded supervisor response")
    result = pairs([line.split("=", 1) for line in process.stdout.decode().splitlines()])
    result.update(unit=unit, invocation_id=result.get("InvocationID"), boot_id=Path("/proc/sys/kernel/random/boot_id").read_text().strip())
    return result


def check(run, expected, *, supervisor=None):
    files = Files()
    run = Path(run).resolve(strict=True)
    require(re.fullmatch(r"ventium-[A-Za-z0-9_.@:-]+\.service", expected["unit"]) is not None and
            re.fullmatch(r"[0-9a-f]{32}", expected["invocation_id"]) is not None, "invalid expected unit identity")
    require(len(expected["affinity"]) == 2 and len(set(expected["affinity"])) == 2 and all(exact_int(n) and n >= 0 for n in expected["affinity"]), "expected two CPUs required")
    require(expected["pins"] and all(Path(path).is_absolute() and SHA.fullmatch(value) for path, value in expected["pins"].items()), "invalid expected pins")
    before, final = files.json(run / "receipt-before.json"), files.json(run / "receipt-final.json")
    for receipt in (before, final):
        resource_receipt(receipt, expected)
    require(before["pid"] == final["pid"] and before["exe_sha256"] == final["exe_sha256"] and before["cgroup"] == final["cgroup"] and
            0 < before["unix"] < final["unix"] <= time.time() + 5, "owner receipt chronology/identity changed")
    require(exact_int(final["matrix_returncode"], 0) and all(final[key] is True for key in ("pins_unchanged", "oom_events_zero", "all_native_children_gone")), "failed/incomplete final owner receipt")
    for path, digest in expected["pins"].items():
        # The exact archived source plus both runtime observations qualify the
        # historical helper. A later canonical helper repair cannot invalidate
        # that frozen run; actual binary/image/compile/header files stay pinned.
        if path != expected["driver_path"]:
            require(files.read(path, digest_only=True) == digest, "pinned input/source changed: " + path)
    launcher = files.json(run / "launcher-pin.json")
    require(launcher["launcher_sha256"] == expected["launcher_sha256"] == files.read(run / "run.py", digest_only=True) and
            launcher["plan_sha256"] == expected["plan_sha256"] == files.read(run / "plan.json", digest_only=True), "launcher/plan changed")
    require(launcher["loaded_driver_sha256"] == expected["pins"][expected["driver_path"]] == files.read(run / "observed-driver.py", digest_only=True), "loaded source archive changed")
    admission = files.json(run / "receipt-native-live.json")
    require(admission["unit"] == expected["unit"] and admission["invocation_id"] == expected["invocation_id"] and admission["main_pid"] == before["pid"], "native admission identity mismatch")
    matrices = list(run.glob("ventium-coremark-matrix.*"))
    require(len(matrices) == 1 and matrices[0].is_dir() and not matrices[0].is_symlink(), "missing/ambiguous matrix")
    matrix = matrices[0]
    plan, loaded = files.json(run / "plan.json"), files.json(matrix / "plan.json")
    require(plan["version"] == loaded["version"] == 1 and len(plan["cases"]) == len(loaded["cases"]) == 1 and len(plan["workloads"]) == len(loaded["workloads"]) == 2, "not exactly one candidate/two seeds")
    case, original_case = loaded["cases"][0], plan["cases"][0]
    require(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", case["label"]), "unsafe candidate label")
    require({k: v for k, v in case.items() if k != "profile"} == original_case, "loaded case differs from launch plan")
    profile = case["profile"]
    require(profile["sha256"] == expected["pins"][case["binary"]] and profile["compile_record_sha256"] == expected["pins"][profile["compile_record"]], "candidate/compile pins mismatch")
    require(profile["model_threads"] == case["model_threads"] == 1 and profile["input_snapshot_capable"] is True and case["skip_unchanged_settle"] is True and case["clock_cycle_probe"] is True and case["memory_backend"] == "direct", "wrong model/runtime profile")
    headers = profile["input_snapshot_generated_headers"]
    require(len(headers) == 2 and {Path(p).name for p in headers} == {"Vventium_top.h", "model_input_snapshot.h"} and all(expected["pins"][p] == value for p, value in headers.items()), "generated header pins missing/changed")
    snapshot = next(p for p in headers if Path(p).name == "model_input_snapshot.h")
    header_sha = next(value for p, value in headers.items() if Path(p).name == "Vventium_top.h")
    require(re.findall(rb"^// Complete generated model-header SHA256: ([0-9a-f]{64})$", files.read(snapshot), re.M) == [header_sha.encode()], "generated input snapshot/header ancestry mismatch")
    observations, native_pids, cpus = [], [], []
    require(len(admission["native_processes"]) == 2, "missing native admission")
    for workload in loaded["workloads"]:
        seed, label = workload["seed"], workload["label"]
        require(seed in CRCS and re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", label), "invalid seed/path label")
        original = [w for w in plan["workloads"] if w["label"] == label]
        require(len(original) == 1 and {k: v for k, v in workload.items() if k != "image_sha256"} == original[0], "loaded workload changed")
        require(workload["iterations"] == 1500 and workload["crcfinal"] == CRCS[seed]["crcfinal"] and workload["max_insn"] == 700000000 and workload["max_cycles"] == 900000000 and workload["timeout_seconds"] == 3600 and workload["image_sha256"] == expected["pins"][workload["image"]], "nonstandard/mutated workload")
        job = matrix / (case["label"] + "--" + label)
        manifest, result = files.json(job / "manifest.json"), files.json(job / "result.json")
        require(manifest["case"] == case and manifest["workload"] == workload and len(manifest["cpus"]) == 1 and manifest["cpus"][0] in expected["affinity"], "job manifest differs")
        cpu = manifest["cpus"][0]
        cpus.append(cpu)
        argv = ["taskset", "--cpu-list", str(cpu), case["binary"], "--quake-image", workload["image"], "--emulate-syscalls", "--no-trace", "--cycle", "--max-insn", "700000000", "--max-cycles", "900000000", "--quiesce", "200000", "--user-stdout", str(job / "guest.stdout"), "--skip-unchanged-settle"]
        require(manifest["argv"] == argv and manifest["environment_overrides"] == {"TB_CLOCK_CYCLE_PROBE": "1"} and manifest["expected_clock_probe"] == {"nr": 403, "clock_id": 0}, "unexpected guest command/probe")
        require(exact_int(result["returncode"], 0) and not any(result.get(key) for key in ("failure", "timed_out", "interrupted", "stopping")), "native wait/cap/interruption failure")
        require(0 < result["wall_seconds"] <= 3600 and before["unix"] <= manifest["started_unix"] < final["unix"], "invalid native timing")
        raw = report(files.read(job / "run.log"), files.read(job / "guest.stdout"), seed)
        require(result["retired"] == raw["retired"] and result["clocks"] == raw["clocks"] and result["crc"] == raw["crc"] and all(result[key] is True for key in ("complete", "crc_ok", "iterations_ok", "dataset_ok", "coremark_report_validated", "guest_duration_ok", "binary_unchanged", "image_unchanged", "compile_record_unchanged", "generated_headers_unchanged", "input_settle_reconciles", "clock_window_valid", "score_eligible")), "result disagrees with independent raw report")
        witnesses = [p for p in admission["native_processes"] if p["workload"] == label]
        require(len(witnesses) == 1, "native workload admission ambiguous")
        native = witnesses[0]
        require(exact_int(native["pid"]) and native["pid"] > 0 and native["pid"] != before["pid"] and
                exact_int(native["starttime_ticks"]) and native["starttime_ticks"] > 0, "invalid actual native PID/starttime")
        require(native["parent_pid"] == before["pid"] and native["actual_affinity"] == [cpu] and native["actual_exe"] == case["binary"] and native["actual_proc_exe_sha256"] == profile["sha256"] and native["process_group"] == native["session_id"] == native["pid"], "actual native admission mismatch")
        native_pids.append(native["pid"])
        observations.append(raw)
    require({r["seed"] for r in observations} == set(CRCS) and set(cpus) == set(expected["affinity"]) and len(set(native_pids)) == 2, "duplicate/missing standard seed or native CPU")
    owner = supervisor if supervisor is not None else query_supervisor(expected["unit"])
    require(owner["unit"] == expected["unit"] and owner["invocation_id"] == expected["invocation_id"] and owner["boot_id"] == Path("/proc/sys/kernel/random/boot_id").read_text().strip(), "unknown/replaced supervisor invocation/boot")
    # systemd clears ControlGroup after removing a successfully closed leaf.
    # Empty is only usable with the exact invocation/wait above and the actual
    # recorded leaf absence/emptiness check below; never as a default success.
    require(owner["ControlGroup"] in ("", final["cgroup"].removeprefix("/sys/fs/cgroup")), "supervisor/recorded cgroup mismatch")
    require(owner["ActiveState"] == "inactive" and owner["SubState"] == "dead" and str(owner["MainPID"]) == "0" and owner["Result"] == "success" and str(owner["ExecMainCode"]) == "1" and str(owner["ExecMainStatus"]) == "0", "owner actual wait/closure not qualified")
    require(not any(Path("/proc", str(pid)).exists() for pid in [before["pid"], *native_pids]), "original owner/native PID still present; cannot prove closure")
    cgroup = Path(final["cgroup"])
    require(not cgroup.exists() or (cgroup / "cgroup.procs").read_text().strip() == "", "owned cgroup remains occupied")
    files.finish()
    return {"status": "PASS", "evidence_class": "observed closed functional evidence", "unit": expected["unit"], "invocation_id": expected["invocation_id"], "supervisor_closure": owner, "seeds": observations,
            "verified_file_sha256": {p: value[1] for p, value in files.observed.items()},
            "limitations": ["Ordinary native log files have no historic sticky capture/write-loss receipt; complete raw reports are observed evidence, not lossless pipe-capture proof.", "Current compile-input source hashes are provenance, not proof of compiler ancestry.", "CoreMark scores/IPC are not gameplay performance measurements."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--expect", required=True, type=Path)
    parser.add_argument("--expect-sha256", required=True)
    parser.add_argument("--supervisor-closure", type=Path)
    parser.add_argument("--supervisor-sha256")
    args = parser.parse_args()
    try:
        files = Files()
        require(SHA.fullmatch(args.expect_sha256) and files.read(args.expect, digest_only=True) == args.expect_sha256, "external expectation pin mismatch")
        expected = files.json(args.expect)
        require(bool(args.supervisor_closure) == bool(args.supervisor_sha256), "external supervisor receipt requires its reviewed SHA256")
        if args.supervisor_closure:
            require(SHA.fullmatch(args.supervisor_sha256) and files.read(args.supervisor_closure, digest_only=True) == args.supervisor_sha256, "external supervisor receipt pin mismatch")
            supervisor = files.json(args.supervisor_closure)
        else:
            supervisor = None
        result = check(args.run, expected, supervisor=supervisor)
        files.finish()
    except (OSError, ValueError, KeyError, TypeError, IndexError, UnicodeError, subprocess.SubprocessError) as exc:
        parser.exit(2, "COREMARK-STANDARD-UNQUALIFIED: " + str(exc) + "\n")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
