#!/usr/bin/env python3
"""Run independent CoreMark RTL experiments, with bounded parallelism.

A JSON plan supplies frozen binary paths and QEMU-produced entry images. Every
run enables cycle mode and suppresses instruction traces. The result records
the exact invocation, input/binary hashes, compile defines, exit, CRCs and all
reported clocks. This driver does not rebuild RTL or modify benchmark inputs.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time


REPO = Path(__file__).resolve().parents[1]
STANDARD_CRCS = {
    "performance": {"seedcrc": "e9f5", "crclist": "e714", "crcmatrix": "1fd7", "crcstate": "8e3a"},
    "validation": {"seedcrc": "18f2", "crclist": "e3c1", "crcmatrix": "0747", "crcstate": "8d84"},
}
NON_P54_DEFINES = {"VEN_UOPCACHE", "VEN_LOAD_USE_FORWARD"}
_children = set()
_children_lock = threading.Lock()
_stopping = threading.Event()


def sha256(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def json_write(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".new")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def positive_integer(value, label):
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ValueError(f"{label} must be a positive integer")
    return value


def parse_crc_output(text):
    found = {}
    for field, value in re.findall(r"(?:\[\d+\])?(seedcrc|crclist|crcmatrix|crcstate|crcfinal)\s*:\s*0x([0-9a-fA-F]+)", text):
        if field in found:
            raise ValueError(f"duplicate CoreMark CRC field: {field}")
        found[field] = f"{int(value, 16):04x}"
    return found


def parse_clock_window(log, retired, clocks, iterations, expected_nr=403, expected_clock_id=0):
    """Accept only the pinned start/stop clock queries, never guest tick math.

    Count every marker before matching its fields: an extra or malformed query
    must not disappear from consideration and turn an ambiguous log into a
    usable benchmark interval. The probe is observational and does not change
    the synthetic values returned to the guest.
    """
    lines = [line for line in log.splitlines() if "[clock-cycle]" in line]
    result = {"clock_window_valid": False, "clock_query_marker_count": len(lines),
              "clock_query_expected_nr": expected_nr,
              "clock_query_expected_clock_id": expected_clock_id}
    if len(lines) != 2:
        result["clock_window_failure"] = "expected exactly two clock-cycle query markers"
        return result
    queries = []
    for line in lines:
        match = re.fullmatch(r"\[clock-cycle\] n=(\d+) nr=(\d+) clock_id=(\d+) cycle=(\d+)", line)
        if match is None:
            result["clock_window_failure"] = "malformed clock-cycle query marker"
            return result
        n, nr, clock_id, cycle = map(int, match.groups())
        queries.append({"n": n, "nr": nr, "clock_id": clock_id, "cycle": cycle})
    result["clock_queries"] = queries
    if any(query["nr"] != expected_nr or query["clock_id"] != expected_clock_id for query in queries):
        result["clock_window_failure"] = "clock queries do not match expected syscall and clock ID"
        return result
    start, stop = queries
    if not (0 <= start["n"] < stop["n"] <= retired
            and 0 <= start["cycle"] < stop["cycle"] <= clocks):
        result["clock_window_failure"] = "clock queries are out of order or outside the completed program"
        return result
    result.update(clock_window_valid=True,
                  clock_window_clocks=stop["cycle"] - start["cycle"],
                  clock_window_retired=stop["n"] - start["n"])
    result["cm_per_mhz_clock_window"] = iterations * 1_000_000 / result["clock_window_clocks"]
    result["clock_window_note"] = "Supplementary exact service-to-service clock delta; conservative whole-program score remains the default."
    return result


def parse_memory_shapes(log):
    """Reconcile compact producer events separately from exclusive clocks."""
    if "-- D-memory producer shape" not in log:
        return {}
    sites = {"S_LOAD", "S_LOAD2", "S_STORE", "FAST_READ", "FAST_WRITE"}
    cells = {}
    summaries = {}
    shape_pattern = (r"\s*mem-shape site=(\w+) width=(\d+) low=(\d+) hit=(\d+) events=(\d+) "
                     r"old_dword_bad=(\d+) true_boundary_bad=(\d+)")
    total_pattern = (r"\s*mem-producer site=(\w+) events=(\d+) cells=(\d+) old_dword_bad=(\d+) "
                     r"true_boundary_bad=(\d+) false_old_bad=(\d+) read_misses=(\d+)")
    for line in log.splitlines():
        if "mem-shape site=" in line:
            match = re.fullmatch(shape_pattern, line)
            if match is None:
                raise ValueError("malformed memory producer shape")
            site = match[1]
            width, low, hit, events, old_bad, true_bad = map(int, match.groups()[1:])
            key = (site, width, low, hit)
            if site not in sites or not (0 <= width < 8 and 0 <= low < 4 and hit in (0, 1)) or key in cells:
                raise ValueError("invalid or duplicate memory producer shape")
            if old_bad != (low != 0) or true_bad != ((width == 2 and low == 3) or (width == 4 and low != 0)):
                raise ValueError("memory producer alignment predicates disagree with their shape")
            cells[key] = {"site": site, "width": width, "low": low, "hit": hit, "events": events,
                          "old_dword_bad": old_bad, "true_boundary_bad": true_bad}
        if "mem-producer site=" in line:
            match = re.fullmatch(total_pattern, line)
            if match is None or match[1] not in sites or match[1] in summaries:
                raise ValueError("invalid or duplicate memory producer summary")
            summaries[match[1]] = dict(zip(("events", "cells", "old_dword_bad", "true_boundary_bad",
                                            "false_old_bad", "read_misses"), map(int, match.groups()[1:])))
    if set(summaries) != sites:
        raise ValueError("memory producer summary is incomplete")
    for site, summary in summaries.items():
        values = [value for value in cells.values() if value["site"] == site]
        events = sum(value["events"] for value in values)
        expected = {"events": events, "cells": events,
                    "old_dword_bad": sum(value["events"] for value in values if value["old_dword_bad"]),
                    "true_boundary_bad": sum(value["events"] for value in values if value["true_boundary_bad"]),
                    "false_old_bad": sum(value["events"] for value in values if value["old_dword_bad"] and not value["true_boundary_bad"]),
                    "read_misses": sum(value["events"] for value in values if value["hit"] == 0 and site not in ("S_STORE", "FAST_WRITE"))}
        if summary != expected:
            raise ValueError("memory producer histogram does not reconcile")
    return {"memory_producer_shapes": list(cells.values()), "memory_producer_summary": summaries,
            "memory_producer_reconciles": True}


def parse_input_settle(log, clocks, requested):
    lines = [line for line in log.splitlines() if "[input-settle]" in line]
    result = {"input_settle_requested": requested}
    if not lines and not requested:
        return result
    if len(lines) != 1 or not requested:
        raise ValueError("missing or unexpected unchanged-input settle report")
    match = re.fullmatch(
        r"\[input-settle\] ports=(\d+) cells=(\d+) mandatory_edge_evals=(\d+) "
        r"full_settle_evals=(\d+) skipped_settle_evals=(\d+)", lines[0])
    if match is None:
        raise ValueError("malformed unchanged-input settle report")
    ports, cells, mandatory, full, skipped = map(int, match.groups())
    if not (ports > 0 and cells >= ports and mandatory == clocks * 2
            and full + skipped == clocks * 2):
        raise ValueError("unchanged-input settle counts do not reconcile with core clocks")
    result.update(input_settle_reconciles=True, input_snapshot_ports=ports,
                  input_snapshot_cells=cells, mandatory_edge_evals=mandatory,
                  full_settle_evals=full, skipped_settle_evals=skipped)
    return result


def parse_result(log, stdout, workload, clock_probe=None, skip_unchanged_settle=False):
    exits = re.findall(r"FREE-RUN guest exit_group\((-?\d+)\) after (\d+) retired in (\d+) clocks", log)
    result = {"complete": False, "crc_ok": False, "score_eligible": False,
              "clock_window_score_eligible": False}
    if len(exits) != 1:
        result["failure"] = "missing or ambiguous normal guest exit"
        return result
    exit_code, retired, clocks = map(int, exits[0])
    result.update(guest_exit_code=exit_code, retired=retired, clocks=clocks)
    if exit_code or not clocks:
        result["failure"] = "guest exit failure or zero clock count"
        return result
    result["complete"] = True
    result["ipc"] = retired / clocks
    result["cm_per_mhz_total_program"] = workload["iterations"] * 1_000_000 / clocks
    probe = clock_probe or {}
    result.update(parse_clock_window(log, retired, clocks, workload["iterations"],
                                    probe.get("nr", 403), probe.get("clock_id", 0)))
    result["clock_window_requested"] = clock_probe is not None
    try:
        actual_crc = parse_crc_output(stdout)
    except ValueError as error:
        result["failure"] = str(error)
        return result
    result["crc"] = actual_crc
    expected = dict(STANDARD_CRCS[workload["seed"]], crcfinal=workload["crcfinal"].lower().removeprefix("0x").zfill(4))
    result["expected_crc"] = expected
    result["crc_ok"] = actual_crc == expected
    iterations = re.findall(r"^Iterations\s*:\s*(\d+)\s*$", stdout, re.MULTILINE)
    result["iterations_ok"] = iterations == [str(workload["iterations"])]
    size = re.findall(r"^CoreMark Size\s*:\s*(\d+)\s*$", stdout, re.MULTILINE)
    result["dataset_ok"] = size == ["666"]
    times = re.findall(r"^Total time \(secs\)\s*:\s*([0-9.]+)\s*$", stdout, re.MULTILINE)
    result["guest_seconds"] = float(times[0]) if len(times) == 1 else None
    result["guest_duration_ok"] = result["guest_seconds"] is not None and result["guest_seconds"] >= 10
    result["coremark_report_validated"] = ("Correct operation validated" in stdout
                                           and "Errors detected" not in stdout and "ERROR!" not in stdout)
    # Short runs are useful diagnostics, but cannot become a completed score by
    # multiplying their iteration/cycle ratio. Guest time is synthetic and is
    # never used for the CM/MHz calculation above.
    result["score_eligible"] = all(result.get(key, False) for key in (
        "crc_ok", "iterations_ok", "dataset_ok", "guest_duration_ok", "coremark_report_validated"))
    try:
        result.update(parse_memory_shapes(log))
    except ValueError as error:
        result.update(memory_producer_reconciles=False, score_eligible=False, failure=str(error))
    try:
        result.update(parse_input_settle(log, clocks, skip_unchanged_settle))
    except ValueError as error:
        result.update(input_settle_reconciles=False, score_eligible=False, failure=str(error))
    marker = log.find("-- clocks by FSM state")
    if marker >= 0:
        block = log[marker:].split("-- memory pressure", 1)[0]
        states = {key: int(value) for key, value in re.findall(r"state\s+(\d+)\s+(\d+)\s+", block)}
        result["fsm_clocks"] = states
        result["fsm_sum"] = sum(states.values())
        result["fsm_reconciles"] = result["fsm_sum"] == clocks
        if not result["fsm_reconciles"]:
            result["score_eligible"] = False
            result["failure"] = "exclusive FSM clock counts do not sum to observed clocks"
        pipe_marker = log.find("-- S_PIPE clocks by FIRST bail arm")
        if pipe_marker >= 0:
            block = log[pipe_marker:].split("-- V-slot result", 1)[0]
            pipe_clocks = {label.strip(): int(value) for value, label in re.findall(
                r"\[\s*\d+\]\s+(\d+)\s+[0-9.]+%\s+([^\n]+)", block)}
            result["pipe_first_arm_clocks"] = pipe_clocks
            result["pipe_first_arm_sum"] = sum(pipe_clocks.values())
            # The FSM enum depends on enabled engine states; never hard-code
            # the number assigned to S_PIPE in another feature profile.
            summaries = re.findall(r"\bS_PIPE clocks\s+(\d+)\s+NON-S_PIPE", log)
            result["pipe_reported_clocks"] = int(summaries[0]) if len(summaries) == 1 else None
            result["pipe_reconciles"] = (result["pipe_reported_clocks"] is not None
                                         and result["pipe_first_arm_sum"] == result["pipe_reported_clocks"]
                                         and result["pipe_reported_clocks"] in states.values())
            if not result["pipe_reconciles"]:
                result["score_eligible"] = False
                result["failure"] = "exclusive S_PIPE bail-arm counts do not sum to S_PIPE clocks"
            pair_marker = "-- V-slot result for U-side ISSUE clocks (sums to ISSUE) --"
            if pair_marker in log:
                pair_block = log.split(pair_marker, 1)[1].split("\n  -- ", 1)[0]
                pair_rows = re.findall(r"^\s+(\d+)\s+([^\n]+)$", pair_block, re.MULTILINE)
                pairs = {label.strip(): int(value) for value, label in pair_rows}
                issue = sum(value for label, value in pipe_clocks.items() if label.startswith("ISSUE "))
                result["pair_first_result_clocks"] = pairs
                result["pair_first_result_sum"] = sum(pairs.values())
                result["pairing_reconciles"] = (len(pairs) == len(pair_rows)
                                                  and sum(pairs.values()) == issue)
                deny_marker = "-- pairing-rule first rejection (sums to !pipe_pair_ok) --"
                if deny_marker in log:
                    deny_block = log.split(deny_marker, 1)[1].split("\n  -- ", 1)[0]
                    deny_rows = re.findall(r"^\s+(\d+)\s+([^\n]+)$", deny_block, re.MULTILINE)
                    deny = {label.strip(): int(value) for value, label in deny_rows}
                    rejected = sum(value for label, value in pairs.items() if label.startswith("!pipe_pair_ok "))
                    result["pair_rule_rejections"] = deny
                    result["pair_rule_rejection_sum"] = sum(deny.values())
                    result["pairing_reconciles"] &= (len(deny) == len(deny_rows)
                                                       and sum(deny.values()) == rejected)
                if not result["pairing_reconciles"]:
                    result["score_eligible"] = False
                    result["failure"] = "V-slot first-result/rejection counts do not sum to ISSUE/reject clocks"
    result["clock_window_score_eligible"] = result["score_eligible"] and result["clock_window_valid"]
    return result


def parse_verilator_threads(record):
    """Read model concurrency from the recorded elaboration, not the plan.

    Threaded experiments keep foreign DPI callbacks on the calling thread.
    The memory/syscall/retire producers are not safe to invoke concurrently.
    """
    commands = re.findall(r'^C "(.*)"$', record, re.MULTILINE)
    if len(commands) != 1:
        raise ValueError("compile record needs exactly one Verilator command")
    tokens = shlex.split(commands[0])
    options = {}
    for index, token in enumerate(tokens):
        for option in ("--threads", "--threads-dpi"):
            if token == option:
                if index + 1 >= len(tokens) or tokens[index + 1].startswith("-"):
                    raise ValueError(f"missing compile option value: {option}")
                value = tokens[index + 1]
            elif token.startswith(option + "="):
                value = token.partition("=")[2]
            else:
                continue
            if option in options:
                raise ValueError(f"duplicate compile option: {option}")
            options[option] = value
    count = options.get("--threads", "1")
    if count not in ("1", "2", "4", "8"):
        raise ValueError("compiled model threads must be 1, 2, 4 or 8")
    count = int(count)
    contexts = [token.partition("=")[2] for token in tokens
                if token == "-DVEN_TB_MODEL_THREADS" or token.startswith("-DVEN_TB_MODEL_THREADS=")]
    if len(contexts) > 1 or (contexts and contexts[0] not in ("1", "2", "4", "8")):
        raise ValueError("ambiguous or unsupported testbench context thread count")
    context_count = int(contexts[0]) if contexts else 1
    if context_count != count:
        raise ValueError("testbench context threads disagree with compiled model threads")
    dpi = options.get("--threads-dpi", "default")
    if count > 1 and dpi != "none":
        raise ValueError("threaded CoreMark models require --threads-dpi none")
    return {"model_threads": count, "threads_dpi": dpi}


def parse_verilator_host_optimization(record):
    """Identify the exact host-only serial-LTO bundle, never an RTL profile."""
    commands = re.findall(r'^C "(.*)"$', record, re.MULTILINE)
    if len(commands) != 1:
        raise ValueError("compile record needs exactly one Verilator command")
    tokens = shlex.split(commands[0])
    makeflags = []
    for index, token in enumerate(tokens):
        if token == "-MAKEFLAGS":
            if index + 1 >= len(tokens):
                raise ValueError("missing compile option value: -MAKEFLAGS")
            makeflags.append(tokens[index + 1])
        elif token.startswith("-MAKEFLAGS="):
            makeflags.append(token.partition("=")[2])
    bundle = ("USER_CPPFLAGS=-flto=1", "USER_LDFLAGS=-flto=1", "AR=gcc-ar")
    lto_tokens = [token.removeprefix("-MAKEFLAGS=") for token in tokens if "flto" in token]
    active = bool(lto_tokens or "AR=gcc-ar" in makeflags)
    if active and (any(makeflags.count(flag) != 1 for flag in bundle)
                   or any(flag not in bundle[:2] for flag in lto_tokens)):
        raise ValueError("compiled host LTO must use the exact serial compile/link/archive bundle")
    return {"host_lto_serial": active, "host_makeflags": makeflags}


def compile_profile(binary, specified=None):
    record = Path(specified) if specified else binary.parent / "Vventium_top__verFiles.dat"
    result = {"binary": str(binary), "sha256": sha256(binary), "compile_record": str(record)}
    if not record.is_file():
        raise ValueError(f"compile record missing for {binary}; specify compile_record")
    text = record.read_text()
    result.update(parse_verilator_threads(text))
    result.update(parse_verilator_host_optimization(text))
    result["input_snapshot_capable"] = bool(re.search(
        r"(?<!\S)-DVEN_TB_INPUT_SNAPSHOT(?:=1)?(?=\s|$|\")", text))
    if result["input_snapshot_capable"]:
        snapshot = binary.parent / "model_input_snapshot.h"
        model_header = binary.parent / "Vventium_top.h"
        if not snapshot.is_file() or not model_header.is_file():
            raise ValueError("snapshot-enabled build is missing its generated headers")
        recorded_header = re.findall(r"^// Complete generated model-header SHA256: ([0-9a-f]{64})$",
                                     snapshot.read_text(), re.MULTILINE)
        if recorded_header != [sha256(model_header)]:
            raise ValueError("input snapshot was not generated from this model header")
        result["input_snapshot_generated_headers"] = {
            str(snapshot): sha256(snapshot), str(model_header): recorded_header[0]}
    defines = sorted(set(re.findall(r"\+define\+([A-Za-z_][A-Za-z_0-9]*)", text)))
    current_inputs = {}
    for source in re.findall(r'^S[^\n]*"([^"\n]+)"\s*$', text, re.MULTILINE):
        path = Path(source)
        if path.is_file():
            current_inputs[str(path)] = sha256(path)
    result.update(compile_record_sha256=sha256(record), defines=defines,
                  current_compile_input_sha256=current_inputs,
                  source_note="Current input hashes are provenance, not proof that an older binary was built from current sources.",
                  p54_fidelity_rejections=sorted(set(defines) & NON_P54_DEFINES))
    return result


def validate_host_lto_plan(case):
    if "host_lto_serial" not in case:
        return
    if not isinstance(case["host_lto_serial"], bool):
        raise ValueError("host_lto_serial must be a boolean")
    if case["host_lto_serial"] != case["profile"]["host_lto_serial"]:
        raise ValueError(f"compiled host LTO disagrees with plan for {case['label']}")


def load_plan(path):
    plan = json.loads(path.read_text())
    if plan.get("version") != 1 or not plan.get("cases") or not plan.get("workloads"):
        raise ValueError("plan needs version=1 and nonempty cases/workloads arrays")
    labels = set()
    for case in plan["cases"]:
        label = case["label"]
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", label) or label in labels:
            raise ValueError("case labels must be unique path-safe names")
        labels.add(label)
        case["binary"] = str(Path(case["binary"]).resolve(strict=True))
        if not os.access(case["binary"], os.X_OK):
            raise ValueError(f"binary is not executable: {case['binary']}")
        case["profile"] = compile_profile(Path(case["binary"]), case.get("compile_record"))
        validate_host_lto_plan(case)
        if "model_threads" in case:
            positive_integer(case["model_threads"], "model_threads")
            if case["model_threads"] != case["profile"]["model_threads"]:
                raise ValueError(f"compiled model threads disagree with plan for {label}")
        if not isinstance(case.get("skip_unchanged_settle", False), bool):
            raise ValueError("skip_unchanged_settle must be a boolean")
        if case.get("skip_unchanged_settle", False) and not case["profile"]["input_snapshot_capable"]:
            raise ValueError(f"unchanged-input acceleration not compiled for {label}")
        if case.get("memory_backend", "direct") != "direct":
            raise ValueError("this version requires the explicit direct-memory backend")
        if not isinstance(case.get("clock_cycle_probe", False), bool):
            raise ValueError("clock_cycle_probe must be a boolean")
        if case.get("clock_cycle_probe_nr", 403) not in (265, 403):
            raise ValueError("clock_cycle_probe_nr must be clock_gettime (265) or clock_gettime64 (403)")
        if case.get("clock_cycle_probe_clock_id", 0) != 0:
            raise ValueError("the pinned CoreMark binary uses CLOCK_REALTIME (clock ID 0)")
    labels.clear()
    for workload in plan["workloads"]:
        label = workload["label"]
        if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", label) or label in labels:
            raise ValueError("workload labels must be unique path-safe names")
        labels.add(label)
        if workload["seed"] not in STANDARD_CRCS:
            raise ValueError("workload seed must be performance or validation")
        for key in ("iterations", "max_insn", "max_cycles", "timeout_seconds"):
            positive_integer(workload[key], key)
        # Explicit user authorization on 2026-09-30 permits one hour per seed.
        # Existing plan deadlines remain unchanged; this is only the hard cap.
        if workload["timeout_seconds"] > 3600:
            raise ValueError("CoreMark runs are currently authorized for at most 3600 seconds")
        if not re.fullmatch(r"(?:0x)?[0-9a-fA-F]{1,4}", workload["crcfinal"]):
            raise ValueError("crcfinal must be a reference hexadecimal CRC")
        workload["image"] = str(Path(workload["image"]).resolve(strict=True))
        workload["image_sha256"] = sha256(workload["image"])
        if workload.get("reference_stdout"):
            reference = Path(workload["reference_stdout"]).resolve(strict=True)
            expected = dict(STANDARD_CRCS[workload["seed"]], crcfinal=workload["crcfinal"].lower().removeprefix("0x").zfill(4))
            if parse_crc_output(reference.read_text()) != expected:
                raise ValueError(f"reference CRC disagrees with plan for {label}")
            workload["reference_stdout_sha256"] = sha256(reference)
    return plan


def resource_limit(requested, rss_mib, reserve_mib):
    affinity = sorted(os.sched_getaffinity(0))
    entries = dict(re.findall(r"^(\w+):\s+(\d+)", Path("/proc/meminfo").read_text(), re.MULTILINE))
    available = int(entries["MemAvailable"]) // 1024
    memory_jobs = max(0, (available - reserve_mib) // rss_mib)
    if not memory_jobs:
        raise ValueError(f"available memory {available} MiB is below reserved headroom")
    return min(32, requested, len(affinity), memory_jobs), affinity, available


def simulation_envelope():
    """Read the actual cgroup caps; an inherited environment is not proof."""
    for line in Path("/proc/self/cgroup").read_text().splitlines():
        parts = line.split(":", 2)
        if len(parts) == 3 and parts[0] == "0":
            cgroup = Path("/sys/fs/cgroup") / parts[2].lstrip("/")
            memory = (cgroup / "memory.max").read_text().strip()
            tasks = (cgroup / "pids.max").read_text().strip()
            if memory.isdecimal() and tasks.isdecimal() and int(memory) <= 4 * 1024**3 and int(tasks) <= 256:
                return {"cgroup": str(cgroup), "memory_max_bytes": int(memory), "tasks_max": int(tasks)}
    return None


def stop_children(signum, _frame):
    _stopping.set()
    with _children_lock:
        for child in tuple(_children):
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass


def is_accepted(result):
    """Completed correctness, independent of score or P54 profile eligibility."""
    required = ("complete", "crc_ok", "iterations_ok", "dataset_ok",
                "coremark_report_validated", "guest_duration_ok", "binary_unchanged",
                "image_unchanged", "compile_record_unchanged", "generated_headers_unchanged")
    return (all(result.get(key) is True for key in required)
            and type(result.get("returncode")) is int and result["returncode"] == 0
            and not any(result.get(key) for key in ("failure", "timed_out", "interrupted", "stopping")))


def run_job(case, workload, directory, cpus):
    job = directory / f"{case['label']}--{workload['label']}"
    job.mkdir()
    invocation = [case["binary"], "--quake-image", workload["image"],
                  "--emulate-syscalls", "--no-trace", "--cycle",
                  "--max-insn", str(workload["max_insn"]), "--max-cycles", str(workload["max_cycles"]),
                  "--quiesce", "200000", "--user-stdout", str(job / "guest.stdout")]
    if case.get("skip_unchanged_settle", False):
        invocation.append("--skip-unchanged-settle")
    if len(cpus) != case["profile"]["model_threads"] or len(cpus) != len(set(cpus)):
        raise ValueError("job CPU allocation does not match compiled model threads")
    argv = ["taskset", "--cpu-list", ",".join(map(str, cpus)), *invocation]
    environment = os.environ.copy()
    environment.pop("TB_CLOCK_CYCLE_PROBE", None)
    clock_probe = None
    if case.get("clock_cycle_probe", False):
        environment["TB_CLOCK_CYCLE_PROBE"] = "1"
        clock_probe = {"nr": case.get("clock_cycle_probe_nr", 403),
                       "clock_id": case.get("clock_cycle_probe_clock_id", 0)}
    manifest = {"case": case, "workload": workload, "argv": argv, "cwd": str(REPO),
                "cpu": cpus[0], "cpus": cpus,
                "model_threads": case["profile"]["model_threads"],
                "skip_unchanged_settle": case.get("skip_unchanged_settle", False),
                "estimated_job_tasks": case["profile"]["model_threads"] + 2,
                "started_unix": time.time(), "memory_backend": "direct",
                "environment_overrides": {"TB_CLOCK_CYCLE_PROBE": environment.get("TB_CLOCK_CYCLE_PROBE")},
                "expected_clock_probe": clock_probe}
    json_write(job / "manifest.json", manifest)
    result = {"case": case["label"], "workload": workload["label"], "artifacts": str(job)}
    if _stopping.is_set():
        result.update(complete=False, interrupted=True, score_eligible=False)
        json_write(job / "result.json", result)
        return result
    start = time.monotonic()
    with (job / "run.log").open("wb") as log:
        process = subprocess.Popen(argv, cwd=REPO, env=environment, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        with _children_lock:
            _children.add(process)
        try:
            returncode = process.wait(timeout=workload["timeout_seconds"])
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                returncode = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                returncode = process.wait()
            result["timed_out"] = True
        finally:
            with _children_lock:
                _children.discard(process)
    result.update(returncode=returncode, wall_seconds=time.monotonic() - start)
    output = job / "guest.stdout"
    result.update(parse_result((job / "run.log").read_text(errors="replace"),
                               output.read_text(errors="replace") if output.exists() else "", workload,
                               clock_probe, case.get("skip_unchanged_settle", False)))
    result["binary_unchanged"] = sha256(case["binary"]) == case["profile"]["sha256"]
    result["image_unchanged"] = sha256(workload["image"]) == workload["image_sha256"]
    result["compile_record_unchanged"] = sha256(case["profile"]["compile_record"]) == case["profile"]["compile_record_sha256"]
    result["generated_headers_unchanged"] = all(sha256(path) == digest for path, digest in
                                                case["profile"].get("input_snapshot_generated_headers", {}).items())
    result["score_eligible"] &= is_accepted(result)
    result["clock_window_score_eligible"] = result["score_eligible"] and result.get("clock_window_valid", False)
    json_write(job / "result.json", result)
    print(f"{result['case']} {result['workload']}: clocks={result.get('clocks', '?')} "
          f"CRC={'OK' if result.get('crc_ok') else 'FAIL'} "
          f"CM/MHz={result.get('cm_per_mhz_total_program', 0):.6f} "
          f"{'completed score candidate' if result['score_eligible'] else 'diagnostic/incomplete'}", flush=True)
    return result


def summarize(plan, results):
    candidates = []
    for case in plan["cases"]:
        values = [item for item in results if item["case"] == case["label"]]
        accepted = [item for item in values if is_accepted(item)]
        eligible = [item for item in accepted if item["score_eligible"]]
        seeds = {next(w["seed"] for w in plan["workloads"] if w["label"] == item["workload"]) for item in accepted}
        candidates.append({"case": case["label"], "both_standard_seeds_complete": seeds == set(STANDARD_CRCS),
                           "minimum_eligible_cm_per_mhz": min((item["cm_per_mhz_total_program"] for item in eligible), default=None),
                           "p54_fidelity_rejections": case["profile"]["p54_fidelity_rejections"],
                           "p54_fidelity_review": case.get("p54_fidelity_review", "not provided"),
                           "results": values})
    return {"candidates": candidates,
            "score_definition": "iterations * 1e6 / total program RTL clocks (includes startup/output; conservative)",
            "supplementary_score_definition": "iterations * 1e6 / verified two-query service-to-service clock delta; only clock_window_score_eligible results qualify",
            "fidelity_note": "Numeric score/CRCs do not establish P54 fidelity; review the named RTL profile independently."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--jobs", type=int, default=32)
    parser.add_argument("--rss-mib-per-job", type=int, default=32)
    parser.add_argument("--reserve-mib", type=int, default=4096)
    parser.add_argument("--output-base", type=Path, default=Path("/tmp"))
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--inside-scope", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        for key in ("jobs", "rss_mib_per_job", "reserve_mib"):
            positive_integer(getattr(args, key), key)
        if args.jobs > 32:
            raise ValueError("jobs must be <=32")
        plan = load_plan(args.plan.resolve(strict=True))
        workers, cpus, available = resource_limit(args.jobs, args.rss_mib_per_job, args.reserve_mib)
        cpus = cpus[:32]
        maximum_threads = max(case["profile"]["model_threads"] for case in plan["cases"])
        if maximum_threads > len(cpus):
            raise ValueError("one compiled model needs more CPUs than the permitted affinity")
        work_count = len(plan["cases"]) * len(plan["workloads"])
        if args.validate_only:
            print(json.dumps({"plan_valid": True, "runs": work_count, "workers": min(workers, work_count),
                              "mem_available_mib": available}, indent=2))
            return
        envelope = simulation_envelope()
        if envelope is None:
            if args.inside_scope:
                raise ValueError("CoreMark simulation scope lacks verified memory/task caps")
            # Simulations have their own small cap and can overlap one bounded
            # compiler build. The build lock must not serialize 32 lightweight
            # simulation experiments behind a Verilator elaboration.
            argv = ["systemd-run", "--user", "--scope", "--quiet",
                    "--unit", f"ventium-coremark-matrix-{os.getpid()}",
                    "-p", "MemoryMax=2G", "-p", "MemorySwapMax=0", "-p", "TasksMax=160",
                    sys.executable, str(Path(__file__).resolve()), *sys.argv[1:], "--inside-scope"]
            return subprocess.call(argv)
        scope_jobs = (envelope["memory_max_bytes"] // (1024 * 1024) - 128) // args.rss_mib_per_job
        # Each job owns one driver worker, one simulation process, N-1 model
        # workers and a possible Verilator runtime helper: conservatively N+2
        # tasks. The heterogeneous allocator below reserves the actual N for
        # each frozen model, rather than pinning all models to one CPU.
        minimum_threads = min(case["profile"]["model_threads"] for case in plan["cases"])
        task_budget = envelope["tasks_max"] - 16
        if maximum_threads + 2 > task_budget:
            raise ValueError("one compiled model exceeds the simulation task budget")
        scope_jobs = min(scope_jobs, task_budget // (minimum_threads + 2))
        if scope_jobs <= 0:
            raise ValueError("simulation memory cap leaves no room for one job and driver")
        workers = min(workers, scope_jobs)
        base = args.output_base.resolve(strict=True)
        if base != Path("/tmp") and REPO not in base.parents:
            raise ValueError("output-base must be /tmp or a directory inside the repository")
        if os.statvfs(base).f_bavail * os.statvfs(base).f_frsize < 256 * 1024 * 1024:
            raise ValueError("output filesystem has less than 256 MiB free")
    except (ValueError, OSError, KeyError) as error:
        parser.error(str(error))
    directory = Path(tempfile.mkdtemp(prefix="ventium-coremark-matrix.", dir=base))
    json_write(directory / "plan.json", plan)
    json_write(directory / "resources.json", {"workers": min(workers, work_count), "cpus": cpus,
               "mem_available_mib": available, "rss_mib_per_job": args.rss_mib_per_job,
               "reserved_memory_mib": args.reserve_mib, "plan_sha256": sha256(args.plan),
               "aggregate_model_cpu_limit": len(cpus), "job_task_budget": task_budget,
               "model_threads": {case["label"]: case["profile"]["model_threads"] for case in plan["cases"]},
               "simulation_envelope": envelope})
    print(f"CoreMark artifacts: {directory}; up to {min(workers, work_count)} workers", flush=True)
    signal.signal(signal.SIGTERM, stop_children)
    signal.signal(signal.SIGINT, stop_children)
    cpu_slots = list(cpus)
    slot_lock = threading.Condition()
    active_job_tasks = 0
    def execute(case, workload):
        nonlocal active_job_tasks
        count = case["profile"]["model_threads"]
        job_tasks = count + 2
        with slot_lock:
            while len(cpu_slots) < count or active_job_tasks + job_tasks > task_budget:
                slot_lock.wait()
            allocated = [cpu_slots.pop() for _ in range(count)]
            active_job_tasks += job_tasks
        try:
            return run_job(case, workload, directory, allocated)
        finally:
            with slot_lock:
                cpu_slots.extend(allocated)
                active_job_tasks -= job_tasks
                slot_lock.notify_all()
    results = []
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(execute, case, workload) for case in plan["cases"] for workload in plan["workloads"]]
        for future in as_completed(futures):
            try:
                results.append(future.result())
            except Exception as error:
                results.append({"case": "unknown", "workload": "unknown", "score_eligible": False, "failure": repr(error)})
            json_write(directory / "summary.json", summarize(plan, results))
    failed = any(not is_accepted(item) for item in results)
    return 1 if _stopping.is_set() or failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
