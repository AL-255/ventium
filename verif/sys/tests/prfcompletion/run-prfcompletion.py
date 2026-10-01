#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Seven directed RF cases; no execution without explicit --execute.

Use run.sh --tb /absolute/prebuilt/tb_ventium --out /absolute/fresh/obj_dir_... .
Default --cases all; a comma-separated distinct subset of1..7 is supported.
Only guest assembly is built (-j1). Native model/compile hashes are observed
before and after; pinned QEMU and verification sources must stay unchanged.
PASS requires strict native133, independent free-QEMU133, complete goldens,
actual closed process groups and unchanged full func--all differential.
Mismatch is RED/exit1; infrastructure/oracle failure is FAIL/exit2. No flags
masks, record filtering, snapshots or DUT rebuilds are performed. Source pins
are observed file provenance, not a stronger loaded-byte ancestry proof.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time

sys.dont_write_bytecode = True
BASE = Path(__file__).resolve().parent
REPO = BASE.parents[3]
PINS = {
    "ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386": "b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd",
    "verif/qemu-trace/gen_trace.py": "4131399c0142c53cdec8e3530f78b29a4f89e7cd49219305522cb376a2507d6b",
    "verif/sys/run-native-system.py": "297c3ab5edf45e0fc4d94ab093f005342ff27113911ad38897009f73c15e893d",
    "verif/diff/compare.py": "fab849a49a0311d2a10f0ca35639e813aaadab6fc3e893b3a311caebb84a7ba4",
    "verif/diff/tracefmt.py": "37a766083afd4d70d7c7edcd474971f5121562a65bae9e7a098c8a19acc7f026",
    "verif/sys/check_faultlog.py": "20654e6bdc70bd426bcf3d469be19046e6de6d8cdc1435f729accb4a9dfb9640"
}


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def port_free(port):
    # Probe both wildcard families, release before QEMU binds. A subsequent
    # external collision is a failure, never an undisclosed fallback port.
    sockets = []
    try:
        for family, address in ((socket.AF_INET, ("0.0.0.0", port)),
                                (socket.AF_INET6, ("::", port))):
            sock = socket.socket(family, socket.SOCK_STREAM)
            sockets.append(sock)
            if family == socket.AF_INET6:
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            sock.bind(address)
    finally:
        for sock in sockets:
            sock.close()


def validate_trace(tracefmt, path, producer, cap):
    if not path.read_bytes().endswith(b"\n"):
        raise ValueError("truncated trace: " + str(path))
    trace = tracefmt.read_trace(str(path))
    if (trace.hdr.get("producer") != producer or trace.mode != "func"
            or trace.hdr.get("sys") is not True or trace.x87
            or not 0 < len(trace.records) < cap):
        raise ValueError("wrong/incomplete trace header or instruction cap")
    for index, row in enumerate(trace.records):
        if type(row.get("n")) is not int or row["n"] != index:
            raise ValueError("noncontiguous/unfiltered trace")
        for field in tracefmt.func_compare_keys(False, True):
            if field not in row or not 0 <= tracefmt.parse_hex(row[field]) < 1 << tracefmt._WIDTH[field]:
                raise ValueError("missing/invalid architectural field " + field)
    return trace


def observations(tracefmt, trace, symbols, case):
    def single(symbol):
        rows = [row for row in trace.records if tracefmt.parse_hex(row["pc"]) == symbols[symbol]]
        if len(rows) != 1:
            raise ValueError("missing/repeated directed PC " + symbol)
        return rows[0]
    seeded = single("seed_iret")
    captured = single("capture_saved_flags")
    source = single("capture_saved_pc")
    terminal = single("supply_exit_code")
    ordinary = single("ordinary_success") if "ordinary_flags" in case else None
    return dict(seed_flags=tracefmt.parse_hex(seeded["eflags"]),
                seed_esp=tracefmt.parse_hex(seeded["esp"]),
                saved_flags=tracefmt.parse_hex(captured["ebp"]),
                saved_pc=tracefmt.parse_hex(source["esi"]),
                terminal_ebp=tracefmt.parse_hex(terminal["ebp"]),
                terminal_esi=tracefmt.parse_hex(terminal["esi"]),
                terminal_edi=tracefmt.parse_hex(terminal["edi"]),
                terminal_ebx=tracefmt.parse_hex(terminal["ebx"]),
                terminal_eax=tracefmt.parse_hex(terminal["eax"]),
                terminal_edx=tracefmt.parse_hex(terminal["edx"]),
                terminal_esp=tracefmt.parse_hex(terminal["esp"]),
                ordinary_flags=tracefmt.parse_hex(ordinary["eflags"]) if ordinary else None,
                ordinary_esp=tracefmt.parse_hex(ordinary["esp"]) if ordinary else None,
                records=len(trace.records))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--cases", default="all")
    parser.add_argument("--tb", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if not args.execute:
        print("PREPARED_NOT_EXECUTED: requires review and explicit --execute")
        return 0
    # No imported verification code or launched command precedes pin checks.
    inputs = {}
    for relative, sha in PINS.items():
        path = REPO / relative
        if digest(path) != sha:
            raise ValueError("pinned input changed before launch: " + relative)
        inputs[str(path)] = sha
    tracefmt = load_module("tracefmt", REPO / "verif/diff/tracefmt.py")
    helper = load_module("native_system", REPO / "verif/sys/run-native-system.py")
    output = args.out
    if (not output.is_absolute() or output != output.resolve() or output.exists()
            or output.is_symlink() or not output.parent.is_dir()
            or output.parent.stat().st_uid != os.getuid()):
        raise ValueError("--out must be fresh absolute nonsymlink owned path")
    relative_output = output.relative_to(REPO)
    if (relative_output.parts[0] != "tmp"
            and not any(part == "obj_dir" or part.startswith("obj_dir_") for part in relative_output.parts)):
        raise ValueError("--out must be inside repo tmp/ or an ignored obj_dir* leaf")
    output.mkdir(mode=0o700)
    receipt_path = output / "summary.json"
    summary = dict(result="FAIL", cases=[], inputs_stable=False, no_dut_rebuild=True,
                   scope="CPL0 protected32 software-RF retention/completion only",
                   model={}, provenance="observed source/file pins; not loaded-byte ancestry")
    helper.save_receipt(receipt_path, summary)
    deadline = time.monotonic() + 500

    def bound(seconds):
        remaining = deadline - time.monotonic() - 5
        if remaining < 1:
            raise ValueError("overall RF-suite time budget exhausted")
        return min(seconds, remaining)

    def command(argv, leaf, label, seconds, expected=(0,)):
        receipt = helper.supervise(argv, leaf / (label + ".stdout"), leaf / (label + ".stderr"),
                                   leaf / (label + ".receipt.json"), bound(seconds))
        if (receipt.get("actual_wait") is not True or receipt.get("group_closed") is not True
                or receipt.get("timed_out") is not False or receipt.get("descendant_leak")
                or receipt.get("cleanup_errors") or receipt.get("signals_after_reap") is not False):
            raise ValueError(label + ": failed actual process closure")
        if receipt["actual_return_code"] not in expected:
            raise ValueError(label + ": unexpected actual exit " + str(receipt["actual_return_code"]))
        receipt.update(result="RED" if label == "full-diff" and receipt["actual_return_code"] == 1 else "PASS",
                       accepted_host_exits=list(expected), process_closure_qualified=True)
        helper.save_receipt(leaf / (label + ".receipt.json"), receipt)
        return receipt

    try:
        active = subprocess.run([str(REPO / "tools/build_scope.sh"), "--is-active"],
                                pass_fds=helper.lock_fds(), timeout=5).returncode
        if active:
            raise ValueError("requires actual inherited normal build_scope")
        tb = args.tb
        compile_record = tb.parent / "Vventium_top__verFiles.dat"
        if (not tb.is_absolute() or tb != tb.resolve() or not tb.is_file()
                or not os.access(tb, os.X_OK) or not compile_record.is_file()):
            raise ValueError("--tb must be an absolute prebuilt executable with its compile record")
        summary["model"] = dict(tb=str(tb), tb_sha256_before=digest(tb),
                                compile_record=str(compile_record), compile_sha256_before=digest(compile_record))
        inputs[str(tb)] = summary["model"]["tb_sha256_before"]
        inputs[str(compile_record)] = summary["model"]["compile_sha256_before"]
        for name in ("prfcompletion.S", "prfcompletion.ld", "Makefile", "manifest.json", "run-prfcompletion.py", "run.sh"):
            inputs[str(BASE / name)] = digest(BASE / name)
        manifest = json.loads((BASE / "manifest.json").read_text())
        selected = list(range(1, 8)) if args.cases == "all" else [int(value) for value in args.cases.split(",")]
        if not selected or len(set(selected)) != len(selected) or any(value not in range(1, 8) for value in selected):
            raise ValueError("--cases must be all or distinct comma-separated IDs1..7")
        manifest_ids = [case["id"] for case in manifest["cases"]]
        if len(manifest_ids) != 7 or set(manifest_ids) != set(range(1, 8)):
            raise ValueError("manifest must contain exactly cases1..7")
        summary["selected_cases"] = selected
        for value in selected:
            port_free(21339 + value)
        summary["ports_preflight"] = [21339 + value for value in selected]
        guest_dir = output / "guest"
        guest_dir.mkdir(mode=0o700)
        os.chdir(BASE)
        command(["/usr/bin/make", "-j1", "OUTDIR=" + str(guest_dir),
                 *[str(guest_dir / f"rf-c{value}.bin") for value in selected]], output, "guest-build", 20)
        qemu = REPO / "ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
        for case in [item for item in manifest["cases"] if item["id"] in selected]:
            leaf = output / ("case" + str(case["id"]))
            leaf.mkdir(mode=0o700)
            image = guest_dir / case["image"]
            elf = image.with_suffix(".elf")
            for path in (image, elf):
                inputs[str(path)] = digest(path)
            case_manifest = {key: value for key, value in manifest.items() if key != "cases"}
            case_manifest.update(name="prfcompletion-c" + str(case["id"]), image=image.name)
            mpath = leaf / "manifest.json"
            helper.save_receipt(mpath, case_manifest)
            inputs[str(mpath)] = digest(mpath)
            command(["/usr/bin/nm", "-n", str(elf)], leaf, "symbols", 5)
            symbols = {parts[2]: int(parts[0], 16) for line in (leaf / "symbols.stdout").read_text().splitlines()
                       if len(parts := line.split()) == 3}
            free = command([str(qemu), "-display", "none", "-machine", "pc", "-cpu", "pentium", "-m", "32",
                            "-no-reboot", "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04", "-bios", str(image)],
                           leaf, "qemu-free", 15, (133,))
            port = 21339 + case["id"]
            port_free(port)
            golden = leaf / "golden.vtrace"
            gen = command([sys.executable, str(REPO / "verif/qemu-trace/gen_trace.py"), "--qemu", str(qemu), "--system",
                           "--cpu", "pentium", "--image", str(image), "--image-mode", "bios", "--out", str(golden),
                           "--port", str(port), "--max-insn", str(manifest["max_insn"]), "--verbose"], leaf, "golden", 45)
            gt = validate_trace(tracefmt, golden, "qemu-gdbstub", manifest["max_insn"])
            go = observations(tracefmt, gt, symbols, case)
            expected_flags = int(case["saved_flags"], 0)
            if (go["seed_flags"] != int(case["seed_flags"], 0)
                    or go["seed_esp"] != int(case.get("seed_esp", "0x90000"), 0)
                    or go["saved_flags"] != expected_flags or go["saved_pc"] != symbols["fault_instruction"]
                    or go["terminal_ebp"] != expected_flags or go["terminal_esi"] != symbols["fault_instruction"]
                    or go["terminal_edi"] != 1 or go["terminal_ebx"] != 0x52460000 + case["id"]
                    or go["terminal_eax"] & 255 != 0x42 or go["terminal_esp"] != 0x90000
                    or ("ordinary_flags" in case and (go["ordinary_flags"] != int(case["ordinary_flags"], 0)
                                                       or go["ordinary_esp"] != 0x90000))
                    or ("terminal_edx" in case and go["terminal_edx"] != int(case["terminal_edx"], 0))):
                raise ValueError("golden failed exact directed RF/PC/flags/memory witness: " + json.dumps(go))
            log = (leaf / "golden.stderr").read_text()
            if (helper.FATAL.search(log) or not log.endswith("\n") or "reached --max-insn" in log
                    or not re.search(r"\[gen_trace\] wrote " + str(len(gt.records)) + r" records .*\(guest exited, code=\d+\)\n$", log)):
                raise ValueError("golden incomplete/fatal/capped generator footer")
            os.chdir(REPO / "verif/tb")
            native = helper.run_native(tb, image, mpath, leaf / "rtl.vtrace", leaf / "rtl.stdout", leaf / "rtl.stderr",
                                       bound(45), faultlog=True)
            nt = validate_trace(tracefmt, leaf / "rtl.vtrace", "rtl", manifest["max_insn"])
            no = observations(tracefmt, nt, symbols, case)
            command([sys.executable, str(REPO / "verif/sys/check_faultlog.py"), str(leaf / "rtl.stdout"),
                     "--expect", f"{case['vector']}:0:{case['canonical_fault_records']}"], leaf, "faultlog", 5)
            diff = command([sys.executable, str(REPO / "verif/diff/compare.py"), "--mode", "func", "--all",
                            str(golden), str(leaf / "rtl.vtrace")], leaf, "full-diff", 10, (0, 1))
            case_result = "PASS" if diff["actual_return_code"] == 0 else "RED"
            summary["cases"].append(dict(id=case["id"], result=case_result, golden=go, native=no,
                                         native_actual_exit=native["actual_return_code"], qemu_free_actual_exit=free["actual_return_code"],
                                         golden_generator_actual_exit=gen["actual_return_code"],
                                         comparator_actual_exit=diff["actual_return_code"], port=port,
                                         canonical_fault_records=case["canonical_fault_records"], fault_route=case["fault_route"],
                                         golden_sha256=digest(golden), rtl_sha256=digest(leaf / "rtl.vtrace")))
            helper.save_receipt(receipt_path, summary)
        completed = [case["id"] for case in summary["cases"]]
        if len(completed) != len(selected) or set(completed) != set(selected):
            raise ValueError("not all selected RF cases completed")
        summary["result"] = "RED" if any(case["result"] == "RED" for case in summary["cases"]) else "PASS"
    except BaseException as exc:
        summary.update(result="FAIL", error=f"{type(exc).__name__}: {exc}")
    finally:
        errors = []
        for path, sha in inputs.items():
            try:
                if digest(path) != sha:
                    errors.append("changed input: " + path)
            except OSError as exc:
                errors.append("unreadable input: " + path + ": " + str(exc))
        for key in ("tb", "compile_record"):
            if key in summary["model"]:
                after = "tb_sha256_after" if key == "tb" else "compile_sha256_after"
                try:
                    summary["model"][after] = digest(summary["model"][key])
                except OSError as exc:
                    errors.append("unreadable final model pin: " + str(exc))
        summary.update(inputs=inputs, inputs_stable=not errors, input_errors=errors)
        if errors:
            summary["result"] = "FAIL"
        helper.save_receipt(receipt_path, summary)
    print("RF-COMPLETION-" + summary["result"] + ": " + str(receipt_path))
    return {"PASS": 0, "RED": 1, "FAIL": 2}[summary["result"]]


if __name__ == "__main__":
    try:
        status = main()
    except Exception as exc:
        # Preflight failures precede launch/output ownership, not fabricated
        # native receipts. Once launched, main persists the owned FAIL summary.
        print(f"RF-COMPLETION-FAIL: {type(exc).__name__}: {exc}", file=sys.stderr)
        status = 2
    sys.exit(status)
