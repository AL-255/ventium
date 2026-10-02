#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Frozen, bounded, no-build full-state fetch-boundary differential."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

import check_witness as checks

REPO, HERE, contracts = checks.REPO, checks.HERE, checks.contracts
spec = importlib.util.spec_from_file_location(
    "pfetchbound_native_supervisor", REPO / "verif/sys/run-native-system.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def command(argv, stem, seconds, deadline, expected):
    allowance = min(seconds, deadline - time.monotonic())
    if allowance <= 0:
        raise ValueError("global 530s microgate bound exhausted")
    out, err, receipt_path = [Path(str(stem) + suffix)
                              for suffix in (".stdout", ".stderr", ".receipt.json")]
    receipt = native.supervise(argv, out, err, receipt_path, allowance)
    if receipt["actual_return_code"] != expected:
        raise ValueError(f"actual child exit {receipt['actual_return_code']} != {expected}; see {stem}")
    receipt.update(result="PASS", expected_return_code=expected,
                   qualification="Closed command status only; not directed/OS correctness.")
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt["actual_return_code"], out, err


def parse_cases(value):
    if value == "all":
        return list(checks.CASES)
    if not re.fullmatch(r"(?:[1-9]|1[0-9]|2[0-2])(?:,(?:[1-9]|1[0-9]|2[0-2]))*", value):
        raise argparse.ArgumentTypeError("--cases must be all or comma-separated 1..22")
    cases = [int(item) for item in value.split(",")]
    if len(cases) != len(set(cases)):
        raise argparse.ArgumentTypeError("duplicate selected case")
    return cases


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tb", type=Path, default=os.environ.get("TB_BIN"))
    parser.add_argument("--tb-sha256", default=os.environ.get("TB_SHA256"))
    parser.add_argument("--compile-record", type=Path)
    parser.add_argument("--compile-sha256", default=os.environ.get("TB_COMPILE_SHA256"))
    parser.add_argument("--compile-cwd", type=Path, default=REPO / "verif/tb")
    parser.add_argument("--fixtures", type=Path, default=HERE)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--modes", choices=("both", "functional", "cycle-func"), default="both")
    parser.add_argument("--cases", type=parse_cases, default="all")
    parser.add_argument("--jobs", type=int, choices=range(1, 23), default=2)
    parser.add_argument("--port-base", type=int, default=41710)
    args = parser.parse_args()
    if args.tb is None or args.tb_sha256 is None or args.compile_sha256 is None:
        parser.error("explicit frozen --tb/TB_BIN and reviewed TB/compile SHA256 pins are mandatory")
    if not 1024 <= args.port_base <= 65536 - max(checks.CASES):
        parser.error("GDB ports must be unprivileged and leave space for twenty-two distinct cases")
    return args


def one_case(case, args, before, deadline):
    leaf = args.out / f"case{case}-{checks.CASES[case]['name']}"
    leaf.mkdir(mode=0o700)
    result = dict(case=case, name=checks.CASES[case]["name"], result="FAIL", results=[], errors=[])
    source = [args.fixtures / f"pfetchbound_{case}.{ext}" for ext in ("bin", "elf")]
    image, elf = leaf / "image.bin", leaf / "image.elf"
    try:
        for original, copied in zip(source, (image, elf)):
            shutil.copyfile(original, copied)
            contracts.pin(copied, before[str(original)])
        sym, bios = contracts.symbols(elf), image.read_bytes()
        checks.validate_image(case, sym, bios)
        free, _, _ = command(
            [contracts.QEMU, "-display", "none", "-machine", "pc", "-cpu", "pentium", "-m", "32",
             "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04", "-bios", image],
            leaf / "free-qemu", 30, deadline, 133)
        generator, out, err = command(
            [sys.executable, "-B", REPO / "verif/qemu-trace/gen_trace.py", "--qemu", contracts.QEMU,
             "--system", "--image", image, "--image-mode", "bios", "--cpu", "pentium",
             "--max-insn", str(checks.MAX_INSN), "--port", str(args.port_base + case - 1),
             "--out", leaf / "qemu.vtrace"], leaf / "qemu", 90, deadline, 0)
        golden = contracts.read_complete_trace(leaf / "qemu.vtrace")
        result["golden_records"] = checks.grade_golden(
            case, golden, contracts.closed_log(out, allow_empty=True) + contracts.closed_log(err),
            sym, bios, generator, free)
        modes = ["functional", "cycle-func"] if args.modes == "both" else [args.modes]
        for mode in modes:
            try:
                mode_leaf = leaf / mode
                mode_leaf.mkdir(mode=0o700)
                argv = [args.tb, "--cosim", "--system", "--image", image,
                        "--max-insn", str(checks.MAX_INSN), "--max-cycles", "1000000",
                        "--quiesce", "400", "--out", mode_leaf / "rtl.vtrace", "+ven_faultlog"]
                if mode == "cycle-func":
                    argv.append("--cycle-func")
                rc, out, err = command(argv, mode_leaf / "rtl", 60, deadline, 133)
                trace = contracts.read_complete_trace(mode_leaf / "rtl.vtrace")
                grade = checks.grade_native(case, trace, contracts.closed_log(out, allow_empty=True),
                                             contracts.closed_log(err), sym, bios, rc)
                command([sys.executable, "-B", REPO / "verif/diff/compare.py", "--mode", "func", "--all",
                         leaf / "qemu.vtrace", mode_leaf / "rtl.vtrace"], mode_leaf / "diff", 30, deadline, 0)
                grade.update(mode=mode, full_architectural_differential=True)
                result["results"].append(grade)
            except Exception as exc:
                result["errors"].append(dict(mode=mode, error=f"{type(exc).__name__}: {exc}"))
        for original, copied in zip(source, (image, elf)):
            contracts.pin(copied, before[str(original)])
        result.update(result="FAIL" if result["errors"] else "PASS", private_inputs_stable=True)
    except Exception as exc:
        result["errors"].append(dict(stage="case", error=f"{type(exc).__name__}: {exc}"))
    (leaf / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    args = parse_args()
    args.tb = args.tb.resolve(strict=True)
    record = (args.compile_record or args.tb.parent / "Vventium_top__verFiles.dat").resolve(strict=True)
    args.fixtures = args.fixtures.resolve(strict=True)
    args.out = contracts.safe_output(args.out)
    active = subprocess.run([str(REPO / "tools/build_scope.sh"), "--is-active"],
                            pass_fds=native.lock_fds(), timeout=5).returncode
    if active:
        raise ValueError("use this folder's run-gate.sh inside the bounded serialized guard")
    defines = contracts.validate_build(args.tb, args.tb_sha256, record, args.compile_sha256,
                                       [], args.compile_cwd)
    contracts.pin(contracts.QEMU, contracts.QEMU_SHA)
    checks.validate_manifest(json.loads((HERE / "manifest.json").read_text()))
    sources = [args.fixtures / f"pfetchbound_{case}.{ext}"
               for case in args.cases for ext in ("bin", "elf")]
    for case in args.cases:
        checks.validate_image(case, contracts.symbols(args.fixtures / f"pfetchbound_{case}.elf"),
                              (args.fixtures / f"pfetchbound_{case}.bin").read_bytes())
    paths = [*sources, args.tb, record, contracts.QEMU, HERE / "pfetchbound.S", HERE / "pfetchbound.ld",
             HERE / "Makefile", HERE / "manifest.json", HERE / "check_witness.py", HERE / "run-gate.sh",
             Path(__file__).resolve(), checks.SHARED, REPO / "verif/sys/run-native-system.py",
             REPO / "verif/sys/check_faultlog.py", REPO / "verif/qemu-trace/gen_trace.py",
             REPO / "verif/diff/compare.py", REPO / "verif/diff/tracefmt.py", REPO / "tools/build_scope.sh"]
    before = {str(path): contracts.digest(path) for path in paths}
    args.out.mkdir(mode=0o700)
    (args.out / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
    deadline = time.monotonic() + 530
    summary = dict(result="FAIL", defines=defines, selected_cases=args.cases, jobs=args.jobs,
                   results=[], errors=[], full_case_set=args.cases == list(checks.CASES),
                   qualification="Selected directed fetch-boundary differentials only; not standard-suite acceptance.")
    print(f"PFETCHBOUND artifacts: {args.out}", flush=True)
    try:
        with ThreadPoolExecutor(max_workers=min(args.jobs, len(args.cases))) as executor:
            tasks = [executor.submit(one_case, case, args, before, deadline) for case in args.cases]
            for task in as_completed(tasks):
                result = task.result()
                summary["results"].append(result)
                print(f"PFETCHBOUND case{result['case']}: {result['result']}", flush=True)
        summary["results"].sort(key=lambda item: item["case"])
        for path, sha in before.items():
            contracts.pin(path, sha)
        failed = [item["case"] for item in summary["results"] if item["result"] != "PASS"]
        if failed:
            summary["errors"].append(dict(stage="cases", failed_cases=failed))
        summary.update(result="FAIL" if summary["errors"] else "PASS", inputs_stable=True)
    except Exception as exc:
        summary["errors"].append(dict(stage="gate", error=f"{type(exc).__name__}: {exc}"))
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2), flush=True)
    return int(summary["result"] != "PASS")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        sys.exit(f"PFETCHBOUND-GATE-FAIL: {exc}")
