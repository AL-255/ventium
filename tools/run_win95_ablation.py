#!/usr/bin/env python3
"""Cold-boot existing Ventium full-PC profiles on isolated CPU/disk copies.

Older binaries are historical screening controls, not causal ablations.
Same-source one-define variants are causal only after their Verilator source
hashes and effective defines have been compared.  Stop a case on the first
observed Win95 VxD error; otherwise run to the cycle cap, one CPU per sim.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

import run_quake_standard as evidence


ROOT = Path(__file__).resolve().parents[1]
PC_DIR = ROOT / "ao486-sim"
CAPTURE_HELPER_SHA = "bf715d90ec99b892e1c8ce5f7ac216821867ede598b278605769998cd27928c0"
ERROR = "Invalid VxD dynamic link call"
TERMINAL_ERROR = re.compile(
    rb"Invalid VxD dynamic link call|Windows protection error|"
    rb"%Error\b|Assertion failed|SNAPSHOT-ERROR:|"
    rb"terminate called|Segmentation fault|AddressSanitizer:|runtime error:",
    re.IGNORECASE)


def terminal_error(output):
    match = TERMINAL_ERROR.search(output)
    return match.group().decode("ascii", errors="replace") if match else None


def final_status(code, error):
    # Neither an idle/cycle cap nor an ordinary host stop proves desktop boot.
    if error:
        return "vxd_error" if error.lower() == ERROR.lower() else "terminal_error"
    return "terminated" if code < 0 else "clean_exit_unqualified" if code == 0 else "sim_error"


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def stop_owned(process):
    """Stop/wait only this still-owned child, never an unrelated/reused group."""
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    return process.wait(timeout=5)


def close_case(case, source_pins):
    """Actual wait + EOF + stable held log/input hashes; never desktop PASS."""
    process, capture, case_dir = case["process"], case["capture"], case["directory"]
    code = process.wait(timeout=5)
    failure = case.get("evidence_error")
    error = case.get("terminal_error")
    outcome = {"pid": process.pid, "exit_code": code, "actual_child_wait": True,
               "process_group_absent_after_wait": False, "desktop_acceptance": False}
    try:
        evidence.require_process_group_absent(process.pid)
        outcome["process_group_absent_after_wait"] = True
        output = capture.finish(timeout=3)
        error = error or terminal_error(output)
        if code == 0 and not error:
            outcome["closed_engine_log"] = evidence.gate.check_closed_log(output)
        capture.snapshot()  # Held-path/content validation after the final grading.
    except (OSError, ValueError) as exc:
        failure = failure or str(exc)
    pins = {**source_pins, **case["input_pins"]}
    observed_after = {}
    for path, expected in pins.items():
        try:
            observed_after[str(path)] = digest(path)
            if observed_after[str(path)] != expected:
                failure = failure or "pinned input/source changed: " + str(path)
        except OSError as exc:
            observed_after[str(path)] = None
            failure = failure or str(exc)
    outcome.update(input_hashes_after=observed_after,
                   input_hashes_before={str(p): sha for p, sha in pins.items()},
                   input_and_observed_source_hashes_unchanged=all(observed_after[str(p)] == sha for p, sha in pins.items()),
                   source_provenance="observed canonical Python sources before/after, not exact loaded-text proof")
    try:
        outcome["closed_private_disk_sha256"] = digest(case_dir / "guest.vhd")
    except OSError as exc:
        failure = failure or str(exc)
    try:
        if not capture.error:
            capture.snapshot()  # Recheck the held evidence after closure/input hashing.
        capture.close()
    except (OSError, ValueError) as exc:
        failure = failure or str(exc)
    outcome.update(vxd_error=bool(error and error.lower() == ERROR.lower()), terminal_error=error,
                   evidence_error=failure, log_capture=capture.receipt(actual_wait=True, returncode=code),
                   status=(final_status(code, error) if error or not failure else "evidence_error"))
    (case_dir / "result.json").write_text(json.dumps(outcome, indent=2) + "\n")
    print(f"DONE {case_dir.name} exit={code} status={outcome['status']}", flush=True)
    return outcome


def binaries():
    result = []
    for objdir in sorted(PC_DIR.glob("obj_dir_*")):
        manifest = objdir / "Vsystem__verFiles.dat"
        if not manifest.is_file():
            continue
        defines = sorted(set(re.findall(r"\+define\+(VEN_[A-Za-z0-9_]+)",
                                        manifest.read_text()[:12000])))
        for binary in sorted(objdir.glob("ao486sim_ven*")):
            if binary.is_file() and os.access(binary, os.X_OK):
                result.append((objdir.name + "__" + binary.name, binary, defines))
    return result


def launch(args):
    source_pins = {Path(__file__).resolve(): digest(Path(__file__).resolve()),
                   Path(evidence.__file__).resolve(): digest(Path(evidence.__file__).resolve()),
                   Path(evidence.gate.__file__).resolve(): digest(Path(evidence.gate.__file__).resolve())}
    if source_pins[Path(evidence.__file__).resolve()] != CAPTURE_HELPER_SHA:
        raise ValueError("reviewed CapturedLog helper source drift")
    out = args.out.resolve()
    if out.exists():
        raise SystemExit(f"Refusing to reuse output directory: {out}")
    source = args.disk.resolve(strict=True)
    cases = binaries()
    if args.extra_binary:
        extra = args.extra_binary.resolve(strict=True)
        manifest = extra.parent / "Vsystem__verFiles.dat"
        defines = sorted(set(re.findall(r"\+define\+(VEN_[A-Za-z0-9_]+)",
                                        manifest.read_text()))) if manifest.is_file() else []
        cases = [("external__" + extra.name, extra, defines)]
    if args.select:
        cases = [case for case in cases if re.search(args.select, case[0])]
        if not cases:
            raise SystemExit(f"No binary matched --select {args.select!r}")
    if len(cases) > len(args.cpus):
        raise SystemExit(f"{len(cases)} profiles but only {len(args.cpus)} CPUs")
    out.mkdir(parents=True)
    source_sha = digest(source)
    bios = None
    bios_sha = None
    if args.bios_dir:
        source_bios = args.bios_dir.resolve(strict=True)
        bios = out / "rom"
        bios.mkdir()
        bios_sha = {}
        for name in ("boot0.rom", "boot1.rom"):
            shutil.copy2(source_bios / name, bios / name)
            bios_sha[name] = digest(bios / name)
            if bios_sha[name] != digest(source_bios / name):
                raise SystemExit(f"BIOS ROM changed while staging {name}")
    (out / "source.json").write_text(json.dumps({
        "source_disk": str(source), "source_sha256": source_sha,
        "cycle_cap": args.cycles, "cpu_list": args.cpus, "rate": args.rate,
        "rtc_rate": args.rtc_rate, "fpga_ddr": args.fpga_ddr,
        "rtc_epoch": (args.rtc_epoch if args.rtc_epoch is not None else
                      946684800 if args.ao486_original else 1789257600),
        "kb_script": args.kb, "kb_start": args.kb_start, "kb_gap": args.kb_gap,
        "fb_every": args.fb_every,
        "vga_div": args.vga_div, "vga_jit": args.vga_jit,
        "bios_dir": str(args.bios_dir) if args.bios_dir else None,
        "bios_sha256": bios_sha,
        "observed_python_source_sha256": {str(p): sha for p, sha in source_pins.items()},
    }, indent=2) + "\n")
    running = []
    for (name, binary, defines), cpu in zip(cases, args.cpus):
        case_dir = out / name
        case_dir.mkdir()
        frozen = case_dir / binary.name
        shutil.copy2(binary, frozen)
        binary_sha = digest(frozen)
        if binary_sha != digest(binary):
            raise SystemExit(f"Binary changed while staging {binary}")
        disk = case_dir / "guest.vhd"
        subprocess.run(["cp", "--sparse=always", str(source), str(disk)], check=True)
        if digest(disk) != source_sha:
            raise SystemExit(f"Disk copy differs from source: {disk}")
        command = ["taskset", "-c", str(cpu), str(frozen),
                   "--ide", str(disk), "--rate", str(args.rate),
                   "--mem", "32", "--cycles", str(args.cycles)]
        if args.ao486_original:
            command.extend(["--ddrlat", "1", "--mouse", "--video-fb",
                            "--fb-out", str(case_dir / "frame.ppm")])
            if bios:
                command.extend(["--bios0", str(bios / "boot0.rom"),
                                "--bios1", str(bios / "boot1.rom")])
        else:
            command.extend(["--rate-rtc", str(args.rtc_rate or args.rate),
                            "--rate-vga", "90000000",
                            "--vgatext-every", "25000000"])
        if args.kb:
            command.extend(["--kb", args.kb, "--kb-start", str(args.kb_start),
                            "--kb-gap", str(args.kb_gap)])
        if args.fb_every:
            command.extend(["--fb-every", str(args.fb_every),
                            "--fb-out", str(case_dir / "frame")])
        if args.vga_div is not None:
            command.extend(["--vga-div", str(args.vga_div)])
        if args.vga_jit is not None:
            command.extend(["--vga-jit", str(args.vga_jit)])
        for option in args.sim_extra:
            command.extend(option.split("=", 1) if "=" in option else [option])
        metadata = {"name": name, "binary": str(binary),
                    "binary_sha256": binary_sha, "defines": defines,
                    "cpu": cpu, "command": command, "source_sha256": source_sha,
                    "bios_sha256": bios_sha, "fpga_ddr": args.fpga_ddr}
        (case_dir / "case.json").write_text(json.dumps(metadata, indent=2) + "\n")
        capture = evidence.CapturedLog(case_dir / "run.log")
        environment = {**os.environ}
        # Diagnostic write dropping cannot qualify an OS boot or persist its
        # real registry/filesystem effects. The private copy accepts all writes.
        environment.pop("VEN_IDE_DROP_WRITES", None)
        if args.fpga_ddr:
            environment["FPGA_DDR"] = str(args.fpga_ddr)
        else:
            environment.pop("FPGA_DDR", None)
        if bios:
            environment.update(AO486_BIOS_DIR=str(bios), AO486_RTC_EPOCH=(
                str(args.rtc_epoch) if args.rtc_epoch is not None else
                "946684800" if args.ao486_original else "1789257600"))
        if args.ao486_original:
            environment.update(TZ="UTC", FAKE_TIME="946684800",
                               LD_PRELOAD=str(ROOT / "tmp/time_shim.so"))
        process = subprocess.Popen(command, cwd=PC_DIR, env=environment,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True, bufsize=0)
        pins = {source: source_sha, binary: binary_sha, frozen: binary_sha}
        if bios:
            pins.update({p: bios_sha[name] for name in bios_sha for p in
                         (bios/name, source_bios/name)})
        case = {"process": process, "directory": case_dir, "capture": capture,
                "input_pins": pins, "terminal_error": None, "evidence_error": None,
                "early_eof_at": None}
        try:
            capture.start(process.stdout)
        except (OSError, ValueError) as exc:
            case["evidence_error"] = str(exc)
            stop_owned(process)
            close_case(case, source_pins)
            continue
        running.append(case)
        print(f"START {name} cpu={cpu} pid={process.pid}", flush=True)

    while running:
        next_running = []
        for case in running:
            process, capture = case["process"], case["capture"]
            try:
                if capture.error:
                    raise ValueError(capture.error)
                case["terminal_error"] = case["terminal_error"] or terminal_error(capture.snapshot())
                if capture.eof and process.poll() is None:
                    if case["early_eof_at"] is None:
                        case["early_eof_at"] = time.monotonic()
                    elif time.monotonic() - case["early_eof_at"] >= evidence.PIPE_EXIT_GRACE:
                        raise ValueError("evidence pipe EOF before simulator exit")
            except (OSError, ValueError) as exc:
                case["evidence_error"] = case["evidence_error"] or str(exc)
            if case["terminal_error"] or case["evidence_error"]:
                stop_owned(process)
            code = process.poll()
            if code is None:
                next_running.append(case)
                continue
            close_case(case, source_pins)
        running = next_running
        if running:
            time.sleep(2)
    print("ABLATION-SCREEN-COMPLETE", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--disk", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--cycles", type=int, default=1_200_000_000)
    parser.add_argument("--rate", type=int, default=45_000_000)
    parser.add_argument("--rtc-rate", type=int,
                        help="RTC timebase for Ventium (default: match --rate)")
    parser.add_argument("--rtc-epoch", type=int,
                        help="guest RTC date, Unix seconds (default: per simulator profile)")
    parser.add_argument("--fpga-ddr", type=int, default=2,
                        help="Ventium DDR bridge model (0 disables, default 2)")
    parser.add_argument("--cpus", default="0-31")
    parser.add_argument("--select", help="regular expression selecting binary case names")
    parser.add_argument("--extra-binary", type=Path, help="run one frozen binary outside the objdirs")
    parser.add_argument("--bios-dir", type=Path, help="freeze an alternative boot0/boot1 ROM pair")
    parser.add_argument("--kb", help="guest keyboard script, e.g. type:1,enter")
    parser.add_argument("--kb-start", type=int, default=25_000_000)
    parser.add_argument("--kb-gap", type=int, default=500_000)
    parser.add_argument("--fb-every", type=int, default=0,
                        help="capture a PPM every N cycles in graphics mode")
    parser.add_argument("--vga-div", type=int, help="override simulator VGA divider")
    parser.add_argument("--vga-jit", type=int, help="override simulator VGA jitter")
    parser.add_argument("--ao486-original", action="store_true",
                        help="use the documented original ao486 core boot settings")
    parser.add_argument("--sim-extra", action="append", default=[],
                        help="extra simulator option, optionally option=value")
    args = parser.parse_args()
    lo, hi = map(int, args.cpus.split("-"))
    args.cpus = list(range(lo, hi + 1))
    launch(args)


if __name__ == "__main__":
    main()
