#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Host-only contracts for the actual normal-system native acceptance helper.

No guest is assembled or executed. Supply an already qualified, frozen RTL
system .vtrace; fake host children copy that file verbatim. Negative parser
tests mutate parsed objects, never hand-format .vtrace JSON.
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("native_system", HERE / "run-native-system.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def normal_log(count, clocks=1000):
    return (f"tb: stop: WIN95 co-sim isa-debug-exit (out 0xf4) after {count} retired in {clocks} clocks\n"
            f"tb: retired {count} instructions in {clocks} clocks (bus: 1 reads, 1 writes)\n"
            "tb: M7.3b win95 co-sim: 0 IN reads serviced (0 dev_in available, cursor at 0), "
            "1 OUT writes consumed, 0 port/size desync(s), isa-debug-exit reached\n")


def fake_child():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--image", required=True, type=Path)
    args, _ = parser.parse_known_args()
    mode = os.environ["NATIVE_SYSTEM_HOST_MODE"]
    fixture = Path(os.environ["NATIVE_SYSTEM_HOST_FIXTURE"])
    trace = native.tracefmt.read_trace(str(fixture))
    shutil.copyfile(fixture, args.out)
    log = normal_log(len(trace.records))
    stdout = ""
    code = int(os.environ.get("NATIVE_SYSTEM_HOST_EXIT", "133"))
    if mode == "zero": code = 0
    if mode == "failed_equal_trace": code = 1
    if mode == "fatal": log += "FATAL: injected host failure\n"
    if mode == "assert": stdout = "Assertion failed: injected host failure\n"
    if mode == "runtime": log += "runtime error: injected host failure\n"
    if mode == "quiescent": log = "tb: stop: quiescent for 400 clocks (core idle)\n"
    if mode == "maxinsn": log = "tb: stop: max-insn reached\n" + log
    if mode == "missing_footer": log = "\n".join(line for line in log.splitlines() if not line.startswith("tb: retired")) + "\n"
    if mode == "duplicate_footer": log += f"tb: retired {len(trace.records)} instructions in 1000 clocks (bus: 1 reads, 1 writes)\n"
    if mode == "truncated_stderr": log = log[:-1]
    if mode == "truncated_stdout": stdout = "unterminated"
    if mode == "desync": log = log.replace("0 port/size desync(s)", "1 port/size desync(s)")
    if mode == "missing_io": log = "\n".join(line for line in log.splitlines() if not line.startswith("tb: M7.3b")) + "\n"
    sys.stdout.write(stdout); sys.stdout.flush()
    sys.stderr.write(log); sys.stderr.flush()
    if mode in ("timeout_zero", "timeout_expected"):
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0 if mode == "timeout_zero" else code))
        time.sleep(30)
    if mode == "signal": os.kill(os.getpid(), signal.SIGKILL)
    if mode == "linger": subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"], stdin=subprocess.DEVNULL)
    if mode == "delete_input": args.image.unlink()
    sys.exit(code)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--fixture-sha256", required=True)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if native.digest(args.fixture) != args.fixture_sha256:
        raise ValueError("host fixture is not the explicitly frozen trace")
    out = native.fresh_path(args.out)
    out.mkdir(mode=0o700)
    trace = native.tracefmt.read_trace(str(args.fixture))
    count = len(trace.records)
    log = normal_log(count)
    cap = count + 100
    results = []
    grade = native.grade_native(trace, "", log, 133, 133, cap)
    assert grade["records"] == count
    results.append(dict(case="grade_positive", result="PASS"))
    negative = {
        "grade_zero": (trace, "", log, 0, cap),
        "grade_failed_equal_trace": (trace, "", log, 1, cap),
        "grade_quiescent": (trace, "", "tb: stop: quiescent for 400 clocks (core idle)\n", 133, cap),
        "grade_maxinsn": (trace, "", "tb: stop: max-insn reached\n" + log, 133, cap),
        "grade_truncated": (trace, "", log[:-1], 133, cap),
        "grade_empty_diagnostics": (trace, "", "", 133, cap),
        "grade_desync": (trace, "", log.replace("0 port/size desync(s)", "1 port/size desync(s)"), 133, cap),
        "grade_runtime": (trace, "", log + "runtime error: injected\n", 133, cap),
        "grade_replay": (trace, "", log.replace("0 dev_in available", "1 dev_in available"), 133, cap),
        "grade_full_cap": (trace, "", log, 133, count),
    }
    for label, mutate in (
        ("missing_field", lambda tr: tr.records[0].pop("cr0")),
        ("wrong_width", lambda tr: tr.records[0].update(cs="0x10000")),
        ("bool_n", lambda tr: tr.records[0].update(n=False)),
        ("bool_field", lambda tr: tr.records[0].update(eax=True)),
        ("sequence", lambda tr: tr.records[-1].update(n=count)),
        ("wrong_header", lambda tr: tr.hdr.update(sys=False)),
    ):
        changed = copy.deepcopy(trace)
        mutate(changed)
        negative["grade_" + label] = (changed, "", log, 133, cap)
    for label, parameters in negative.items():
        try:
            native.grade_native(*parameters[:4], 133, parameters[4])
        except (ValueError, TypeError) as exc:
            results.append(dict(case=label, result="PASS", rejected=str(exc)))
        else:
            raise AssertionError("production grade accepted " + label)
    # Execute the actual production launcher with this script as a fake HOST
    # executable. Its trace is byte-for-byte the qualified fixture, including
    # the failed_equal_trace case; successful comparison cannot override exit.
    image = out / "host-image.bin"
    image.write_bytes(b"host-only image; no processor execution\n")
    manifest = out / "manifest.json"
    manifest.write_text(json.dumps(dict(exit_code=133, max_insn=cap, exit_method="isa-debug-exit",
                                        exit_port="0xf4", sys=True, image_bytes=image.stat().st_size)) + "\n")
    source_mode = Path(__file__).stat().st_mode
    if not source_mode & 0o111:
        raise ValueError("host test script must be executable for the fake-native integration")
    os.environ["NATIVE_SYSTEM_HOST_FAKE"] = "1"
    os.environ["NATIVE_SYSTEM_HOST_FIXTURE"] = str(args.fixture)
    modes = ["positive", "zero", "failed_equal_trace", "fatal", "assert", "runtime", "quiescent",
             "maxinsn", "missing_footer", "duplicate_footer", "truncated_stderr", "truncated_stdout",
             "desync", "missing_io", "timeout_zero", "timeout_expected", "signal", "linger", "delete_input"]
    for mode in modes:
        leaf = out / mode
        leaf.mkdir()
        private_image = leaf / "host-image.bin"
        shutil.copyfile(image, private_image)
        os.environ["NATIVE_SYSTEM_HOST_MODE"] = mode
        passed = False
        failure = None
        try:
            native.run_native(Path(__file__).resolve(), private_image, manifest, leaf / "rtl.vtrace",
                              leaf / "stdout", leaf / "stderr", wall_seconds=0.5 if mode.startswith("timeout") else 5)
            passed = True
        except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
            failure = str(exc)
        receipt_path = leaf / "stdout.receipt.json"
        receipt = json.loads(receipt_path.read_text())
        assert passed == (mode == "positive"), (mode, passed)
        assert receipt["actual_wait"] and receipt["group_closed"], (mode, receipt)
        assert not receipt["signals_after_reap"] and not native.group_members(receipt["process_group"])
        for stream in ("stdout", "stderr"):
            assert native.digest(leaf / stream) == receipt[stream + "_sha256"]
        assert receipt["result"] == ("PASS" if passed else "FAIL")
        if mode.startswith("timeout"):
            assert receipt["timed_out"] and receipt["cleanup_signals"] == [signal.SIGTERM]
            assert receipt["actual_return_code"] == (0 if mode == "timeout_zero" else 133)
        if mode == "failed_equal_trace":
            assert native.digest(leaf / "rtl.vtrace") == args.fixture_sha256
            assert receipt["actual_return_code"] == 1
        if mode == "linger": assert receipt["descendant_leak"]
        if mode == "delete_input": assert not receipt["inputs_stable"] and receipt["input_pin_errors"]
        results.append(dict(case="launch_" + mode, result="PASS", rejection=failure,
                            receipt=str(receipt_path), actual_return_code=receipt["actual_return_code"],
                            timed_out=receipt["timed_out"], descendant_leak=receipt["descendant_leak"]))
    # Exercise the admission/cleanup exception paths in the ACTUAL supervisor.
    # The direct child stays unreaped until safe group cleanup and final wait.
    os.environ["NATIVE_SYSTEM_HOST_MODE"] = "positive"
    original_proc, original_members = native.proc_state, native.group_members
    for mode in ("fast_exit_admission", "admission_failure", "census_failure"):
        leaf = out / mode
        leaf.mkdir()
        calls = [0]
        def altered_proc(pid):
            calls[0] += 1
            if calls[0] == 1:
                if mode == "admission_failure": raise OSError("injected admission failure")
                if mode == "fast_exit_admission": time.sleep(0.2)
            return original_proc(pid)
        def altered_members(group):
            calls[0] += 1
            if calls[0] == 1: raise OSError("injected census failure")
            return original_members(group)
        if mode == "census_failure": native.group_members = altered_members
        else: native.proc_state = altered_proc
        passed = False
        try:
            native.run_native(Path(__file__).resolve(), image, manifest, leaf / "rtl.vtrace",
                              leaf / "stdout", leaf / "stderr", wall_seconds=5)
            passed = True
        except (ValueError, OSError):
            pass
        finally:
            native.proc_state, native.group_members = original_proc, original_members
        receipt_path = leaf / "stdout.receipt.json"
        receipt = json.loads(receipt_path.read_text())
        assert passed == (mode == "fast_exit_admission"), (mode, receipt)
        assert receipt["actual_wait"] and receipt["group_closed"] and not receipt["signals_after_reap"]
        assert not native.group_members(receipt["process_group"])
        if not passed: assert receipt["cleanup_errors"] and receipt["result"] == "FAIL"
        results.append(dict(case=mode, result="PASS", receipt=str(receipt_path),
                            actual_return_code=receipt["actual_return_code"]))
    # Rejected reuse must not truncate any existing evidence.
    old_stdout = out / "positive/stdout"
    before = native.digest(old_stdout)
    try:
        native.run_native(Path(__file__).resolve(), image, manifest, out / "positive/rtl.vtrace",
                          old_stdout, out / "positive/stderr")
    except ValueError:
        pass
    else:
        raise AssertionError("accepted nonfresh native outputs")
    assert native.digest(old_stdout) == before
    results.append(dict(case="fresh_output_reuse_rejected", result="PASS"))
    assert native.digest(args.fixture) == args.fixture_sha256
    summary = dict(result="PASS", fixture=str(args.fixture), fixture_sha256=args.fixture_sha256,
                   production_helper_sha256=native.digest(HERE / "run-native-system.py"),
                   cases=results, count=len(results), scope="host-only; no guest assembly/model/QEMU/RTL execution")
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("NATIVE-SYSTEM-HOST-OK:", len(results), "production checker/launcher contracts")


if __name__ == "__main__":
    if os.environ.get("NATIVE_SYSTEM_HOST_FAKE") == "1" and "--image" in sys.argv:
        fake_child()
    else:
        main()
