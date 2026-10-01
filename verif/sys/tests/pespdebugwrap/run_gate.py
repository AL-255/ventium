#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Bounded frozen prebuilt ESP/#DB gate; no implicit assembly/model build."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
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


def selected_cases(text):
    if text == "all":
        return [1, 2]
    if not re.fullmatch(r"[12](?:,[12])*", text):
        raise ValueError("--cases must be all or comma-separated1,2")
    result = [int(item) for item in text.split(",")]
    if len(result) != len(set(result)):
        raise ValueError("duplicate case")
    return result


def validate_profile(args):
    defines = contracts.validate_build(args.tb, args.tb_sha256, args.compile_record,
                                       args.compile_sha256, [], args.compile_cwd)
    if "VEN_SEG_ENFORCE" not in defines:
        raise ValueError("actual compiled VEN_SEG_ENFORCE is mandatory")
    return defines


def run_case(case, args, deadline):
    out = args.out / f"case{case}"
    out.mkdir(mode=0o700)
    source = [args.fixtures / f"pespdebugwrap-c{case}.{ext}" for ext in ("bin", "elf")]
    before = {str(path): contracts.digest(path) for path in source}
    image, elf = out / "image.bin", out / "image.elf"
    for original, target in zip(source, (image, elf)):
        shutil.copyfile(original, target)
        contracts.pin(target, before[str(original)])
    sym, bios = contracts.symbols(elf), image.read_bytes()
    checks.validate_image(case, sym, bios)
    free_rc = contracts.command(
        [contracts.QEMU, "-display", "none", "-machine", "pc", "-cpu", "pentium",
         "-m", "32", "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04", "-bios", image],
        out / "free-qemu.log", 30, deadline, 133)
    q_rc = contracts.command(
        [sys.executable, "-B", REPO / "verif/qemu-trace/gen_trace.py", "--qemu", contracts.QEMU,
         "--system", "--image", image, "--image-mode", "bios", "--cpu", "pentium",
         "--max-insn", str(checks.MAX_INSN), "--port", str(args.port_base + case),
         "--out", out / "qemu.vtrace"], out / "qemu.log", 90, deadline, 0)
    golden = contracts.read_complete_trace(out / "qemu.vtrace")
    checks.grade_golden(golden, contracts.closed_log(out / "qemu.log"), case, sym, bios, q_rc, free_rc)
    rc = contracts.command(
        [args.tb, "--cosim", "--system", "--image", image, "--max-insn", str(checks.MAX_INSN),
         "--max-cycles", "1000000", "--quiesce", "400", "--out", out / "rtl.vtrace", "+ven_faultlog"],
        out / "rtl.stdout", 60, deadline, 133, stderr=out / "rtl.stderr")
    native = contracts.read_complete_trace(out / "rtl.vtrace")
    receipt = checks.grade_native(native, contracts.closed_log(out / "rtl.stdout", allow_empty=True),
                                  contracts.closed_log(out / "rtl.stderr"), case, sym, bios, rc)
    contracts.command([sys.executable, "-B", REPO / "verif/diff/compare.py", "--mode", "func", "--all",
                       out / "qemu.vtrace", out / "rtl.vtrace"], out / "diff.log", 30, deadline, 0)
    for path, value in before.items():
        contracts.pin(path, value)
    for original, target in zip(source, (image, elf)):
        contracts.pin(target, before[str(original)])
    receipt.update(oracle="pinned QEMU full architectural differential", inputs=before,
                   tb_sha256=args.tb_sha256, compile_sha256=args.compile_sha256,
                   variant=checks.variant(case),
                   artifacts={path.name: contracts.digest(path) for path in (
                       image, elf, out / "qemu.vtrace", out / "rtl.vtrace", out / "rtl.stdout",
                       out / "rtl.stderr", out / "qemu.log", out / "free-qemu.log", out / "diff.log")})
    (out / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tb", type=Path, required=True)
    parser.add_argument("--tb-sha256", required=True)
    parser.add_argument("--compile-record", type=Path)
    parser.add_argument("--compile-sha256", required=True)
    parser.add_argument("--compile-cwd", type=Path, default=REPO / "verif/tb")
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--cases", default="all")
    parser.add_argument("--jobs", type=int, choices=(1, 2), default=1)
    parser.add_argument("--port-base", type=int, default=41590)
    return parser.parse_args()


def main():
    args = parse_args()
    cases = selected_cases(args.cases)
    args.tb = args.tb.resolve(strict=True)
    args.compile_record = (args.compile_record or args.tb.parent / "Vventium_top__verFiles.dat").resolve(strict=True)
    args.fixtures = args.fixtures.resolve(strict=True)
    args.out = contracts.safe_output(args.out)
    if not args.fixtures.is_dir() or not 1024 <= args.port_base <= 65533:
        raise ValueError("invalid prebuilt fixture directory or port range")
    active = subprocess.run([str(REPO / "tools/build_scope.sh"), "--is-active"],
                            pass_fds=contracts.lock_fds(), timeout=5).returncode
    if active:
        raise ValueError("use run-pespdebugwrap-gate.sh inside serialized bounded guard")
    defines = validate_profile(args)
    contracts.pin(contracts.QEMU, contracts.QEMU_SHA)
    manifest = json.loads((HERE / "manifest.json").read_text())
    if (manifest["exit_code"], manifest["max_insn"], manifest["cases"], manifest["expected_faults"],
            manifest["expected_debug_traps"], manifest["required_defines"]) != (133, checks.MAX_INSN, 2, [], 1, ["VEN_SEG_ENFORCE"]):
        raise ValueError("unreviewed fixture manifest contract")
    paths = [Path(__file__).resolve(), HERE / "check_witness.py", HERE / "pespdebugwrap.S",
             HERE / "pespdebugwrap.ld", HERE / "Makefile", HERE / "manifest.json", checks.SHARED,
             REPO / "verif/sys/run-pespdebugwrap-gate.sh", args.tb, args.compile_record, contracts.QEMU,
             REPO / "verif/qemu-trace/gen_trace.py", REPO / "verif/diff/compare.py",
             REPO / "verif/diff/tracefmt.py", REPO / "verif/sys/check_faultlog.py", REPO / "tools/build_scope.sh"]
    for case in cases:
        image, elf = [args.fixtures / f"pespdebugwrap-c{case}.{ext}" for ext in ("bin", "elf")]
        paths.extend([image, elf])
        checks.validate_image(case, contracts.symbols(elf), image.read_bytes())
    before = {str(path): contracts.digest(path) for path in paths}
    deadline = time.monotonic() + 530
    args.out.mkdir(mode=0o700)
    (args.out / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
    print(f"PESPDEBUGWRAP artifacts: {args.out}", flush=True)
    results, errors = [], []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_case, case, args, deadline): case for case in cases}
        for future in as_completed(futures):
            try:
                results.append(future.result())
            except Exception as error:
                errors.append(dict(case=futures[future], error=str(error)))
    for path, value in before.items():
        contracts.pin(path, value)
    summary = dict(result="FAIL" if errors else "PASS", cases=cases, jobs=args.jobs,
                   errors=errors, results=sorted(results, key=lambda item: item["case"]),
                   defines=defines, inputs_stable=True,
                   qualification="Directed explicit ESP/#DB metadata differential; no OS/standard-suite acceptance.")
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2), flush=True)
    return int(bool(errors))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"PESPDEBUGWRAP-GATE-FAIL: {error}", file=sys.stderr)
        sys.exit(1)
