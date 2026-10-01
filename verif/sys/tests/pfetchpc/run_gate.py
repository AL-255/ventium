#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Frozen no-build full-state fetch-PC differential, normal and cycle_mode=1."""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

import check_witness as checks

REPO, HERE, contracts = checks.REPO, checks.HERE, checks.contracts
spec = importlib.util.spec_from_file_location(
    "pfetchpc_native_supervisor", REPO / "verif/sys/run-native-system.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def command(argv, stem, seconds, deadline, expected):
    allowance = min(seconds, deadline - time.monotonic())
    if allowance <= 0:
        raise ValueError("global530s microgate bound exhausted")
    out, err, receipt_path = [Path(str(stem) + suffix)
                              for suffix in (".stdout", ".stderr", ".receipt.json")]
    receipt = native.supervise(argv, out, err, receipt_path, allowance)
    if receipt["actual_return_code"] != expected:
        raise ValueError(f"actual child exit {receipt['actual_return_code']} != {expected}; see {stem}")
    receipt.update(result="PASS", expected_return_code=expected,
                   qualification="Closed command status only; not directed/OS correctness.")
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt["actual_return_code"], out, err


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
    parser.add_argument("--port", type=int, default=41697)
    args = parser.parse_args()
    if args.tb is None or args.tb_sha256 is None or args.compile_sha256 is None:
        parser.error("explicit frozen --tb/TB_BIN and reviewed TB/compile SHA256 pins are mandatory")
    return args


def main():
    args = parse_args()
    args.tb = args.tb.resolve(strict=True)
    record = (args.compile_record or args.tb.parent / "Vventium_top__verFiles.dat").resolve(strict=True)
    fixtures = args.fixtures.resolve(strict=True)
    args.out = contracts.safe_output(args.out)
    if not 1024 <= args.port <= 65535:
        raise ValueError("invalid unprivileged GDB port")
    active = subprocess.run([str(REPO / "tools/build_scope.sh"), "--is-active"],
                            pass_fds=native.lock_fds(), timeout=5).returncode
    if active:
        raise ValueError("use this folder's run-gate.sh inside the bounded serialized guard")
    defines = contracts.validate_build(args.tb, args.tb_sha256, record, args.compile_sha256,
                                       [], args.compile_cwd)
    contracts.pin(contracts.QEMU, contracts.QEMU_SHA)
    manifest = json.loads((HERE / "manifest.json").read_text())
    if (manifest.get("exit_code"), manifest.get("max_insn"), manifest.get("image_bytes"),
            manifest.get("cases")) != (133, checks.MAX_INSN, 65536, 2):
        raise ValueError("unreviewed directed manifest contract")
    source = [fixtures / f"pfetchpc.{ext}" for ext in ("bin", "elf")]
    checks.validate_image(contracts.symbols(source[1]), source[0].read_bytes())
    paths = [*source, args.tb, record, contracts.QEMU, HERE / "pfetchpc.S", HERE / "pfetchpc.ld",
             HERE / "Makefile", HERE / "manifest.json", HERE / "check_witness.py", HERE / "run-gate.sh",
             Path(__file__).resolve(), checks.SHARED, REPO / "verif/sys/run-native-system.py",
             REPO / "verif/sys/check_faultlog.py", REPO / "verif/qemu-trace/gen_trace.py",
             REPO / "verif/diff/compare.py", REPO / "verif/diff/tracefmt.py", REPO / "tools/build_scope.sh"]
    before = {str(path): contracts.digest(path) for path in paths}
    args.out.mkdir(mode=0o700)
    (args.out / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
    image, elf = args.out / "image.bin", args.out / "image.elf"
    for original, copied in zip(source, (image, elf)):
        shutil.copyfile(original, copied)
        contracts.pin(copied, before[str(original)])
    sym, bios = contracts.symbols(elf), image.read_bytes()
    checks.validate_image(sym, bios)
    deadline = time.monotonic() + 530
    summary = dict(result="FAIL", defines=defines, results=[], errors=[],
                   qualification="Directed precise fetch-PC differential only; not standard-suite acceptance.")
    print(f"PFETCHPC artifacts: {args.out}", flush=True)
    try:
        free, _, _ = command(
            [contracts.QEMU, "-display", "none", "-machine", "pc", "-cpu", "pentium", "-m", "32",
             "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04", "-bios", image],
            args.out / "free-qemu", 30, deadline, 133)
        generator, out, err = command(
            [sys.executable, "-B", REPO / "verif/qemu-trace/gen_trace.py", "--qemu", contracts.QEMU,
             "--system", "--image", image, "--image-mode", "bios", "--cpu", "pentium",
             "--max-insn", str(checks.MAX_INSN), "--port", str(args.port), "--out", args.out / "qemu.vtrace"],
            args.out / "qemu", 90, deadline, 0)
        golden = contracts.read_complete_trace(args.out / "qemu.vtrace")
        checks.grade_golden(golden, contracts.closed_log(out, allow_empty=True)
                            + contracts.closed_log(err), sym, bios, generator, free)
        modes = ["functional", "cycle-func"] if args.modes == "both" else [args.modes]
        for mode in modes:
            try:
                leaf = args.out / mode
                leaf.mkdir(mode=0o700)
                argv = [args.tb, "--cosim", "--system", "--image", image,
                        "--max-insn", str(checks.MAX_INSN), "--max-cycles", "1000000",
                        "--quiesce", "400", "--out", leaf / "rtl.vtrace", "+ven_faultlog"]
                if mode == "cycle-func":
                    argv.append("--cycle-func")
                rc, out, err = command(argv, leaf / "rtl", 60, deadline, 133)
                trace = contracts.read_complete_trace(leaf / "rtl.vtrace")
                result = checks.grade_native(trace, contracts.closed_log(out, allow_empty=True),
                                             contracts.closed_log(err), sym, bios, rc)
                command([sys.executable, "-B", REPO / "verif/diff/compare.py", "--mode", "func", "--all",
                         args.out / "qemu.vtrace", leaf / "rtl.vtrace"], leaf / "diff", 30, deadline, 0)
                result.update(mode=mode, full_architectural_differential=True)
                summary["results"].append(result)
            except Exception as exc:
                summary["errors"].append(dict(mode=mode, error=f"{type(exc).__name__}: {exc}"))
        for path, sha in before.items():
            contracts.pin(path, sha)
        for original, copied in zip(source, (image, elf)):
            contracts.pin(copied, before[str(original)])
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
        sys.exit(f"PFETCHPC-GATE-FAIL: {exc}")
