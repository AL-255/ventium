#!/usr/bin/env python3
"""Cold FreeDOS Quake timedemo, on private frozen inputs; no snapshots.

Run under a descendant-containing memory/task-limited supervisor. A fresh live
result only requests a graceful host stop; acceptance is checked again after
the simulator exits and closes its disk. A cycle/time cap is never a pass.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import check_quake_timedemo as gate


ROOT = Path(__file__).resolve().parents[1]


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


def copy_checked(source, target):
    before = gate.digest(source)
    shutil.copy2(source, target)
    if gate.digest(target) != before or gate.digest(source) != before:
        raise ValueError(f"input changed while freezing {source}")
    return before


def run(args):
    if args.cycles <= 0 or args.seconds <= 0:
        raise ValueError("cycle and wall-time bounds must be positive")
    if args.cpu not in os.sched_getaffinity(0):
        raise ValueError("requested CPU not available in supervisor affinity")
    source = args.disk.resolve(strict=True)
    binary = args.binary.resolve(strict=True)
    bios = args.bios_dir.resolve(strict=True)
    if args.out.is_symlink():
        raise ValueError(f"refusing output symlink {args.out}")
    out = args.out.resolve()
    # Refuse all reuse, including symlinks, and never write the input disk.
    if out.exists() or out.is_symlink():
        raise ValueError(f"refusing to reuse output directory {out}")
    out.mkdir(parents=True)
    frozen = out / "ao486sim_ven"
    binary_sha = copy_checked(binary, frozen)
    rom = out / "rom"
    rom.mkdir()
    rom_sha = {name: copy_checked(bios / name, rom / name)
               for name in ("boot0.rom", "boot1.rom")}
    disk = out / "guest.vhd"
    disk_sha = gate.digest(source)
    subprocess.run(["cp", "--sparse=always", "--", str(source), str(disk)], check=True)
    if gate.digest(disk) != disk_sha or gate.digest(source) != disk_sha:
        raise ValueError("disk changed while staging private copy")
    # A private writable copy is needed even when the input was immutable.
    # Permission changes do not alter the guest bytes or the source file.
    disk.chmod(disk.stat().st_mode | 0o200)
    receipt = gate.baseline(disk)
    write_json(out / "baseline.json", receipt)
    stop = out / "stop.request"
    command = ["taskset", "-c", str(args.cpu), str(frozen),
               "--ide", str(disk), "--rate", "45000000",
               "--rate-rtc", "45000000", "--rate-vga", "90000000",
               "--mem", "32", "--cycles", str(args.cycles), "--mouse",
               "--ven-perf-every", "100000000", "--vgatext-every", "100000000",
               "--fb-every", "100000000", "--fb-out", str(out / "frame"),
               "--stop-request", str(stop)]
    write_json(out / "inputs.json", {
        "binary": str(binary), "binary_sha256": binary_sha,
        "source_disk": str(source), "source_disk_sha256": disk_sha,
        "rom_sha256": rom_sha, "command": command,
        "rtc_epoch": 1789257600, "FPGA_DDR": 2,
        "wall_seconds_cap": args.seconds, "cold_reset": True,
        "snapshots": False, "guest_modifications": False,
    })
    environment = dict(os.environ, AO486_BIOS_DIR=str(rom),
                       AO486_RTC_EPOCH="1789257600", FPGA_DDR="2")
    environment.pop("VEN_IDE_DROP_WRITES", None)
    log_path = out / "run.log"
    started = time.monotonic()
    reason = None
    deadline = started + args.seconds
    with log_path.open("wb") as log:
        process = subprocess.Popen(command, cwd=ROOT / "ao486-sim",
                                   env=environment, stdout=log, stderr=subprocess.STDOUT)
        try:
            write_json(out / "running.json", {"pid": process.pid, "cpu": args.cpu})
            print(f"START FreeDOS Quake demo1 pid={process.pid} cpu={args.cpu}", flush=True)
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    reason = reason or "wall-time bound reached before qualification"
                    stop.write_text("bounded host stop; not an acceptance marker\n")
                    try:
                        process.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                    break
                # Normal progress logs are small. Stop a flood before a whole
                # log read can exhaust the runtime's fixed memory envelope.
                if log_path.stat().st_size > 64 * 1024 * 1024:
                    reason = "evidence log exceeded 64 MiB budget"
                    stop.write_text("log budget exceeded; preserve evidence\n")
                    deadline = min(deadline, time.monotonic() + 30)
                    time.sleep(15)
                    continue
                engine_log = log_path.read_bytes()
                # Check engine errors even if a concurrently read FAT entry is
                # transiently unavailable. Guest architectural faults alone
                # are not terminal errors.
                if gate.ENGINE_ERROR_RE.search(engine_log) or gate.GUEST_ERROR_RE.search(engine_log):
                    reason = "terminal simulator/guest error"
                    stop.write_text("terminal error; preserve evidence\n")
                    deadline = min(deadline, time.monotonic() + 30)
                else:
                    try:
                        observation = gate.check(disk, receipt, engine_log)
                        if observation["status"] == "OBSERVED_UNQUALIFIED":
                            write_json(out / "observation.json", observation)
                            stop.write_text("fresh timedemo observed; close disk for final checking\n")
                            deadline = min(deadline, time.monotonic() + 30)
                    except (OSError, ValueError, subprocess.SubprocessError):
                        # Live reads can race guest FAT updates. Only the
                        # closed-disk final check is authoritative.
                        pass
                time.sleep(15)
            returncode = process.wait()
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    try:
        if log_path.stat().st_size > 64 * 1024 * 1024:
            raise ValueError("evidence log exceeded 64 MiB budget")
        result = gate.check(disk, receipt, log_path.read_bytes(),
                            stopped=True, returncode=returncode)
        if reason:
            result = {"status": "FAIL", "reason": reason, "closed_disk_check": result}
        elif result["status"] != "PASS":
            result = {"status": "FAIL", "reason": "no completed timedemo", "closed_disk_check": result}
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        result = {"status": "FAIL", "reason": str(exc)}
    result.update(sim_returncode=returncode, elapsed_seconds=time.monotonic() - started)
    write_json(out / "result.json", result)
    print(json.dumps(result), flush=True)
    return 0 if result["status"] == "PASS" else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--disk", type=Path, required=True)
    parser.add_argument("--bios-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument("--cycles", type=int, default=9_000_000_000)
    parser.add_argument("--seconds", type=int, default=259200)
    return run(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
