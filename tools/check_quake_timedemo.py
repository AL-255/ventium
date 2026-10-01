#!/usr/bin/env python3
"""Read-only cold-run Quake acceptance from the FAT16 QCONSOLE.LOG.

Record a clean baseline before launching the private disk. Check only after the
simulator has been reaped and its disk handles closed. --live is an advisory
probe: concurrent mtype reads can be incomplete and can NEVER produce PASS.
The caller owns cold-reset/input provenance; this tool never launches a guest,
changes a disk, or treats a cycle cap/gameplay/checkpoint as timedemo success.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import struct
import subprocess
import time


LOG_PATH = "::/QUAKE/ID1/QCONSOLE.LOG"
CONSOLE_MAX_BYTES = 16 * 1024 * 1024
MTYPE_STDERR_MAX_BYTES = 64 * 1024
MTYPE_TIMEOUT_SECONDS = 15
ENGINE_LOG_MAX_BYTES = 64 * 1024 * 1024
RESULT_RE = re.compile(
    rb"^\s*(\d{1,5})\s+frames\s+(\d+(?:\.\d+)?)\s+seconds\s+"
    rb"(\d+(?:\.\d+)?)\s+fps\s*$", re.MULTILINE | re.IGNORECASE)
ENGINE_ERROR_RE = re.compile(
    rb"%Error\b|Assertion failed|SNAPSHOT-ERROR:|RETIRE-STOP-FAIL\b|"
    rb"terminate called|Segmentation fault|AddressSanitizer:|runtime error:",
    re.IGNORECASE)
GUEST_ERROR_RE = re.compile(
    rb"Host_Error:|Sys_Error:|Exiting due to signal|"
    rb"(?:General Protection Fault|Page fault) at eip=|"
    # DOS Quake 1.06's Sys_Error prints "Error: %s", not "Sys_Error:".
    # sim_ven's VGA text rows have a "  |" prefix. Anchor either form at
    # the start of a line, so diagnostic prose containing "Error:" is not
    # mistaken for the guest's fatal banner; horizontal whitespace only.
    rb"^[ \t]*(?:\|[ \t]*)?Error:", re.IGNORECASE | re.MULTILINE)
RESET_RE = re.compile(rb">>> ventium-soc: reset released; running up to (\d+) cycles\n")
PROGRESS_START_RE = re.compile(rb"\[[ \t]*\d+\] retires=")
PROGRESS_RE = re.compile(
    rb"\[[ \t]*(\d+)\] retires=(\d+) cs=[0-9a-f]{4}:eip=[0-9a-f]{8} "
    rb"cr0=[0-9a-f]{8} cr3=[0-9a-f]{8} eflags=[0-9a-f]{8}\n", re.IGNORECASE)
DONE_RE = re.compile(
    rb">>> done: cyc=(\d+) retires=(\d+) last cs=[0-9a-f]{4}:eip=[0-9a-f]{8}\n",
    re.IGNORECASE)
DEMO_RE = re.compile(rb"Playing\s+demo\s+from\s+demo1\.dem\b", re.IGNORECASE)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def fat16_offset(path):
    """Fail closed on ambiguous/invalid MBR or FAT16 geometry; no magic offset."""
    path = Path(path)
    size = path.stat().st_size
    with path.open("rb") as stream:
        mbr = stream.read(512)
        if len(mbr) != 512 or mbr[510:] != b"\x55\xaa" or size % 512:
            raise ValueError("not a sector-aligned MBR disk")
        parts = [mbr[446 + i * 16:462 + i * 16] for i in range(4)]
        parts = [part for part in parts if part[4] != 0]
        if len(parts) != 1 or parts[0][4] not in (0x04, 0x06, 0x0e):
            raise ValueError("require one unambiguous primary FAT16 partition")
        part = parts[0]
        start, sectors = struct.unpack_from("<II", part, 8)
        if part[0] not in (0, 0x80) or not start or not sectors or (start + sectors) * 512 > size:
            raise ValueError("invalid FAT16 partition extent")
        offset = start * 512
        stream.seek(offset)
        boot = stream.read(512)
    if len(boot) != 512 or boot[510:] != b"\x55\xaa":
        raise ValueError("invalid FAT16 boot sector")
    bps, spc, reserved, fats, roots, total16 = struct.unpack_from("<HBHBHH", boot, 11)
    fat_sectors = struct.unpack_from("<H", boot, 22)[0]
    total = total16 or struct.unpack_from("<I", boot, 32)[0]
    overhead = reserved + fats * fat_sectors + (roots * 32 + 511) // 512
    if (bps != 512 or not spc or spc > 128 or spc & (spc - 1) or
            not reserved or fats not in (1, 2) or not roots or not fat_sectors or
            total != sectors or total <= overhead):
        raise ValueError("invalid FAT16 BPB/partition geometry")
    clusters = (total - overhead) // spc
    if not 4085 <= clusters < 65525 or (clusters + 2) * 2 > fat_sectors * 512:
        raise ValueError("partition is not a correctly sized FAT16 filesystem")
    return offset


def _capture_bounded(command, *, stdout_limit, stderr_limit, timeout):
    """Read both pipes without ever buffering more than each cap plus one.

    The extra byte detects overflow. No communicate()/drain follows a failure:
    kill and reap only this read-only utility, then close its pipe handles.
    The same deadline covers pipe collection and a child that closes its pipes
    but keeps running. Returned output or exception diagnostics stay bounded.
    """
    deadline = time.monotonic() + timeout
    stdout, stderr = bytearray(), bytearray()
    with selectors.DefaultSelector() as selector:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            for pipe, data, limit, name in ((process.stdout, stdout, stdout_limit, "QCONSOLE.LOG"),
                                           (process.stderr, stderr, stderr_limit, "mtype stderr")):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, (data, limit, name))
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                for key, _ in selector.select(remaining):
                    data, limit, name = key.data
                    chunk = os.read(key.fd, min(65536, limit + 1 - len(data)))
                    if not chunk:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    data.extend(chunk)
                    if len(data) > limit:
                        raise ValueError(f"{name} exceeded {limit}-byte output limit")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, timeout)
            returncode = process.wait(timeout=remaining)
            if returncode:
                raise subprocess.CalledProcessError(returncode, command,
                                                    output=bytes(stdout), stderr=bytes(stderr))
            return subprocess.CompletedProcess(command, returncode, bytes(stdout), bytes(stderr))
        except subprocess.TimeoutExpired as exc:
            exc.output, exc.stderr = bytes(stdout), bytes(stderr)
            raise
        finally:
            # mtype is read-only, so immediate termination cannot truncate a
            # guest write. Never drain potentially unbounded output here.
            try:
                if process.poll() is None:
                    process.kill()
                process.wait()
            finally:
                process.stdout.close()
                process.stderr.close()


def read_console(path):
    offset = fat16_offset(path)
    # mtype is read-only; do not use mcopy/mattrib/mtools repair options here.
    result = _capture_bounded(["mtype", "-i", f"{Path(path).resolve()}@@{offset}", LOG_PATH],
                              stdout_limit=CONSOLE_MAX_BYTES, stderr_limit=MTYPE_STDERR_MAX_BYTES,
                              timeout=MTYPE_TIMEOUT_SECONDS)
    return offset, result.stdout


def results(console):
    return [{"frames": int(m[1]), "seconds": m[2].decode("ascii"),
             "fps": m[3].decode("ascii")} for m in RESULT_RE.finditer(console)]


def baseline(path):
    offset, console = read_console(path)
    if results(console):
        raise ValueError("source QCONSOLE.LOG already contains a timedemo result")
    return {"schema": 1, "disk_sha256": digest(path), "partition_offset": offset,
            "qconsole_sha256": hashlib.sha256(console).hexdigest(), "results": []}


def check_closed_log(engine_log):
    """Reject demonstrably tainted cold-run records, not legitimate PS detours.

    Buffered stdout diagnostics may prefix an intact stderr progress record on
    the same line, so search the byte stream rather than anchoring line starts.
    A quota-truncated progress record followed by recovered output must not
    disappear from parsing. PS IDE service can tick the DUT in an unbounded
    polling loop: there is no valid maximum progress interval. This grammar
    check does not prove that whole output records were never silently lost;
    the capturing supervisor must separately verify its pipe/file integrity.
    """
    resets = list(RESET_RE.finditer(engine_log))
    ends = list(DONE_RE.finditer(engine_log))
    if (len(resets) != 1 or engine_log.count(b">>> ventium-soc: reset released;") != 1 or
            not 0 < int(resets[0][1]) <= (1 << 64) - 1 or len(ends) != 1 or engine_log.count(b">>> done:") != 1 or
            not all(0 < int(v) <= (1 << 64) - 1 for v in ends[0].groups()) or
            resets[0].end() > ends[0].start()):
        raise ValueError("incomplete/ambiguous cold reset or normal final report")
    progress = list(PROGRESS_RE.finditer(engine_log))
    if {m.start() for m in PROGRESS_START_RE.finditer(engine_log)} != {m.start() for m in progress}:
        raise ValueError("incomplete progress record; whole-run evidence is tainted")
    previous_cycle = previous_retire = 0
    for record in progress:
        cycle, retired = map(int, record.groups())
        if (not resets[0].end() <= record.start() < record.end() <= ends[0].start() or
                not 500000 <= cycle - previous_cycle or cycle > (1 << 64) - 1 or
                not previous_retire <= retired <= (1 << 64) - 1):
            raise ValueError("progress records are outside the cold run or counters regress")
        previous_cycle, previous_retire = cycle, retired
    final_cycle, final_retire = map(int, ends[0].groups())
    if (final_cycle < previous_cycle or final_retire < previous_retire or
            (final_cycle >= 500000 and not progress)):
        raise ValueError("missing progress or final counters precede progress")
    return {"complete_progress_records": len(progress), "final_cycle": final_cycle,
            "final_retires": final_retire, "maximum_progress_interval_not_bounded": True}


def check(path, receipt, engine_log, *, stopped=False, returncode=None):
    if len(engine_log) > ENGINE_LOG_MAX_BYTES:
        raise ValueError("evidence log exceeded 64 MiB budget")
    if (not isinstance(receipt, dict) or receipt.get("schema") != 1 or receipt.get("results") != [] or
            any(not re.fullmatch(r"[0-9a-f]{64}", str(receipt.get(key, "")))
                for key in ("disk_sha256", "qconsole_sha256"))):
        raise ValueError("invalid/unclean pre-run baseline receipt")
    offset, console = read_console(path)
    if offset != receipt.get("partition_offset"):
        raise ValueError("FAT16 partition geometry changed from the baseline")
    if ENGINE_ERROR_RE.search(engine_log) or GUEST_ERROR_RE.search(engine_log + b"\n" + console):
        raise ValueError("simulator/guest terminal error in acceptance evidence")
    if b">>> STATE LOADED from " in engine_log:
        raise ValueError("cold-run acceptance cannot use a restored snapshot")
    found = results(console)
    if hashlib.sha256(console).hexdigest() == receipt["qconsole_sha256"] or not found:
        return {"status": "PENDING", "reason": "no fresh timedemo result"}
    if not DEMO_RE.search(console):
        raise ValueError("QCONSOLE.LOG does not identify the requested demo1 playback")
    result = found[-1]
    seconds, fps = float(result["seconds"]), float(result["fps"])
    if result["frames"] != 969 or not all(math.isfinite(v) and v > 0 for v in (seconds, fps)):
        raise ValueError("demo1 requires 969 frames and positive finite seconds/fps")
    # Quake rounds these fields independently. Their rounding intervals must
    # admit one consistent frame rate; no expected-performance threshold applies.
    half = lambda text: 0.5 * 10 ** (-len(text.partition(".")[2]))
    sec_delta, fps_delta = half(result["seconds"]), half(result["fps"])
    if (969 / (seconds + sec_delta) > fps + fps_delta + 1e-9 or
            (seconds > sec_delta and 969 / (seconds - sec_delta) < fps - fps_delta - 1e-9)):
        raise ValueError("inconsistent printed frame/seconds/fps fields")
    if not stopped:
        return {"status": "OBSERVED_UNQUALIFIED", "result": result,
                "reason": "live disk observation; stop/reap and recheck"}
    if returncode != 0:
        raise ValueError("require reaped simulator exit 0")
    log_records = check_closed_log(engine_log)
    return {"status": "PASS", "result": result, "partition_offset": offset,
            "log_records": log_records,
            "qconsole_sha256": hashlib.sha256(console).hexdigest(), "disk_sha256": digest(path)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("baseline", "check"))
    parser.add_argument("--disk", required=True, type=Path)
    parser.add_argument("--baseline", type=Path, help="clean pre-run JSON receipt")
    parser.add_argument("--log", type=Path, help="complete simulator stdout/stderr")
    parser.add_argument("--stopped", action="store_true", help="caller has reaped simulator and closed its disk")
    parser.add_argument("--sim-returncode", type=int, help="actual reaped subprocess return code")
    args = parser.parse_args()
    if args.mode == "check" and (args.baseline is None or args.log is None):
        parser.error("check requires --baseline and --log")
    if args.mode == "baseline" and (args.baseline or args.log or args.stopped or args.sim_returncode is not None):
        parser.error("baseline takes only --disk; redirect its JSON to a new receipt")
    if not args.stopped and args.sim_returncode is not None:
        parser.error("--sim-returncode requires --stopped")
    try:
        if args.mode == "baseline":
            evidence = baseline(args.disk)
        else:
            with args.log.open("rb") as stream:
                engine_log = stream.read(ENGINE_LOG_MAX_BYTES + 1)
            evidence = check(args.disk, json.loads(args.baseline.read_text()), engine_log,
                             stopped=args.stopped, returncode=args.sim_returncode)
    except (OSError, ValueError, subprocess.SubprocessError, OverflowError) as exc:
        parser.exit(2, f"QUAKE-TIMEDEMO-FAIL: {exc}\n")
    print(json.dumps(evidence, indent=2))
    return 0 if args.mode == "baseline" or evidence["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
