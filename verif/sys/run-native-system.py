#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Closed native acceptance for normal isa-debug-exit system differentials.

This is not an oracle and does not compare or filter records. The caller must
still run the ordinary full architectural differential. SMM and partial-oracle
witness runners have different contracts and do not use this helper.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "verif/diff"))
import tracefmt

LOG_LIMIT = 16 * 1024 * 1024
FATAL = re.compile(r"%Error|Assertion|FATAL|CPU HUNG|UNIMPLEMENTED|runtime error:|"
                   r"terminate called|^tb: (?:FAIL|ERROR):", re.IGNORECASE | re.MULTILINE)


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def grade_native(trace, stdout, stderr, return_code, expected_exit, max_insn):
    """Production acceptance function; host contracts import this exact code."""
    if return_code != expected_exit:
        raise ValueError(f"actual native exit {return_code} != manifest {expected_exit}")
    if (trace.hdr.get("vtrace") != tracefmt.VERSION or trace.hdr.get("producer") != "rtl"
            or trace.mode != "func" or trace.hdr.get("sys") is not True or trace.x87):
        raise ValueError("wrong native functional system trace header")
    rows = trace.records
    if not rows or len(rows) >= max_insn:
        raise ValueError("empty or instruction-cap-exhausted native trace")
    required = tracefmt.func_compare_keys(False, True)
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or type(row.get("n")) is not int or row["n"] != index:
            raise ValueError("noncontiguous/unfiltered native trace")
        if any(key not in row for key in required):
            raise ValueError("missing architectural native field")
        for key in required + [key for key in tracefmt.SYS_SEG_HIDDEN if key in row]:
            value = row[key]
            if type(value) not in (str, int):
                raise ValueError(f"invalid native field type: {key}")
            parsed = tracefmt.parse_hex(value)
            if not 0 <= parsed < 1 << tracefmt._WIDTH[key]:
                raise ValueError(f"out-of-range native field: {key}")
    for name, log in (("stdout", stdout), ("stderr", stderr)):
        if len(log.encode("utf-8")) > LOG_LIMIT or (log and not log.endswith("\n")):
            raise ValueError(f"truncated/oversized native {name}")
    if not stderr or FATAL.search(stdout) or FATAL.search(stderr):
        raise ValueError("empty/fatal native diagnostics")
    # Streams are closed before inspection; never splice buffered live streams.
    lines = stdout.splitlines() + stderr.splitlines()
    stops = [line for line in lines if line.startswith("tb: stop:")]
    stop = (re.fullmatch(r"tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) "
                         r"after (\d+) retired in (\d+) clocks", stops[0])
            if len(stops) == 1 else None)
    footers = [re.fullmatch(r"tb: retired (\d+) instructions in (\d+) clocks "
                            r"\(bus: \d+ reads, \d+ writes\)", line)
               for line in lines if line.startswith("tb: retired")]
    if (not stop or int(stop[1]) != len(rows) or int(stop[2]) <= 0 or len(footers) != 1
            or not footers[0] or footers[0].groups() != stop.groups()):
        raise ValueError("missing/duplicate/mismatching normal debug-exit/retirement footer")
    io_lines = [line for line in lines if line.startswith("tb: M7.3b")]
    io = (re.fullmatch(r"tb: M7.3b win95 co-sim: (\d+) IN reads serviced "
                       r"\((\d+) dev_in available, cursor at (\d+)\), (\d+) OUT writes consumed, "
                       r"(\d+) port/size desync\(s\), isa-debug-exit reached", io_lines[0])
          if len(io_lines) == 1 else None)
    # Plain --cosim enables real I/O requests, not device-input replay. Legitimate
    # test I/O counts may vary; do not hardcode one OUT/zero IN for all fixtures.
    if not io or int(io[2]) or int(io[3]) or int(io[4]) < 1 or int(io[5]):
        raise ValueError("missing/duplicate/replayed/desynchronized real-I/O footer")
    return dict(records=len(rows), clocks=int(stop[2]), in_reads=int(io[1]), out_writes=int(io[4]))


def proc_state(pid):
    text = Path(f"/proc/{pid}/stat").read_text()
    fields = text[text.rfind(")") + 2:].split()
    return dict(state=fields[0], group=int(fields[2]), session=int(fields[3]), start=fields[19])


def group_members(group):
    members = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            info = proc_state(entry.name)
        except (FileNotFoundError, ProcessLookupError):
            continue
        if info["group"] == group and info["state"] != "Z":
            members.append(int(entry.name))
    return members


def lock_fds():
    return tuple(int(path.name) for path in Path("/proc/self/fd").iterdir()
                 if path.resolve() == Path("/tmp/ventium-heavy-build.lock"))


def save_receipt(path, receipt):
    Path(path).write_text(json.dumps(receipt, indent=2) + "\n")


def supervise(argv, stdout, stderr, receipt_path, wall_seconds):
    """Own a dedicated, non-escaping native group and persist failures as well.

    WNOWAIT holds the child PID until group cleanup finishes. No poll()/wait()
    reaps it early, and no killpg is attempted after the actual final wait.
    The enclosing mandatory build_scope cgroup is the broader containment.
    """
    receipt = dict(result="FAIL", launched=False, argv=list(map(str, argv)), actual_return_code=None, actual_wait=False,
                   timed_out=False, descendant_leak=[], group_closed=False,
                   cleanup_signals=[], cleanup_errors=[], signals_after_reap=False)
    process = None
    start = time.monotonic()
    error = None
    try:
        with Path(stdout).open("xb") as output, Path(stderr).open("xb") as diagnostics:
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("VEN_", "AO486_", "VTM_"))}
            process = subprocess.Popen(["prlimit", f"--fsize={LOG_LIMIT}", "--core=0", "--",
                                        *map(str, argv)], stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=diagnostics, env=env,
                                       start_new_session=True, pass_fds=lock_fds())
            receipt["launched"] = True
            receipt["process_group"] = process.pid
            anchor = None
            try:
                anchor = proc_state(process.pid)
                if anchor["group"] != process.pid or anchor["session"] != process.pid:
                    raise ValueError("native did not enter its dedicated process group/session")
                deadline = start + wall_seconds
                while os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is None:
                    if time.monotonic() >= deadline:
                        receipt["timed_out"] = True
                        break
                    time.sleep(0.01)
            except BaseException as exc:
                error = exc
                receipt["cleanup_errors"].append(f"{type(exc).__name__}: {exc}")
            finally:
                # The unreaped leader's start time, PGID and SID anchor every
                # signal. Even normal-exit leaked children are cleaned *before*
                # wait() releases the PID. Cleanup never makes such a run PASS.
                def census():
                    try:
                        return group_members(process.pid)
                    except Exception as exc:
                        note = f"group census failed: {type(exc).__name__}: {exc}"
                        if note not in receipt["cleanup_errors"]:
                            receipt["cleanup_errors"].append(note)
                        return None

                members = census()
                if not receipt["timed_out"] and members:
                    receipt["descendant_leak"] = members
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    if members == []:
                        break
                    try:
                        # WNOWAIT proves the PID is still our unreaped child;
                        # OS PGID/SID checks remain available if /proc admission
                        # or census failed. Such infrastructure errors still FAIL.
                        os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                        if os.getpgid(process.pid) != process.pid or os.getsid(process.pid) != process.pid:
                            raise ValueError("native no longer owns its dedicated group/session")
                        if anchor is not None:
                            try:
                                current = proc_state(process.pid)
                            except Exception as exc:
                                receipt["cleanup_errors"].append(f"anchor recheck failed: {exc}")
                            else:
                                if any(current[key] != anchor[key] for key in ("start", "group", "session")):
                                    raise ValueError("native ownership anchor changed; refusing signal")
                        try:
                            os.killpg(process.pid, sig)
                        except ProcessLookupError:
                            pass  # Members may have exited after the census.
                        else:
                            receipt["cleanup_signals"].append(int(sig))
                        end = time.monotonic() + 1
                        while (members := census()) != [] and time.monotonic() < end:
                            time.sleep(0.01)
                    except Exception as exc:
                        receipt["cleanup_errors"].append(f"group cleanup failed: {type(exc).__name__}: {exc}")
                receipt["group_closed"] = census() == []
                # Always attempt actual wait, even when admission/census/cleanup
                # failed. Nothing below this point signals the numeric group.
                try:
                    receipt["actual_return_code"] = process.wait(timeout=2)
                    receipt["actual_wait"] = True
                except Exception as exc:
                    receipt["cleanup_errors"].append(f"actual wait failed: {type(exc).__name__}: {exc}")
    except BaseException as exc:
        error = exc
        receipt["cleanup_errors"].append(f"{type(exc).__name__}: {exc}")
    finally:
        # Regular files are closed and an actual status retained even for a
        # timeout/failed child. Never substitute the outer guard's return code.
        receipt["wall_seconds"] = time.monotonic() - start
        for name, path in (("stdout", stdout), ("stderr", stderr)):
            if Path(path).is_file():
                receipt[name + "_sha256"] = digest(path)
        save_receipt(receipt_path, receipt)
    if error:
        raise error
    if (receipt["timed_out"] or receipt["descendant_leak"] or receipt["cleanup_errors"] or not receipt["actual_wait"]
            or not receipt["group_closed"]):
        raise ValueError("native timeout/leak/incomplete closure; see " + str(receipt_path))
    return receipt


def fresh_path(path):
    path = Path(path)
    if (not path.is_absolute() or path != path.resolve() or path.exists() or path.is_symlink()
            or not path.parent.is_dir() or path.parent.stat().st_uid != os.getuid()):
        raise ValueError("output must be fresh absolute nonsymlink owned path: " + str(path))
    return path


def run_native(tb, image, manifest_path, out, stdout, stderr, wall_seconds=90, faultlog=False):
    if not 0 < wall_seconds <= 90:
        raise ValueError("native wall bound must be positive and <=90 seconds")
    out, stdout, stderr = [fresh_path(path) for path in (out, stdout, stderr)]
    receipt_path = fresh_path(str(stdout) + ".receipt.json")
    if len({out, stdout, stderr, receipt_path}) != 4:
        raise ValueError("native output paths collide")
    pins = {}
    # Once fresh receipt ownership is established, even a preflight failure is
    # explicit and labelled not-launched (not an invented native wait status).
    save_receipt(receipt_path, dict(result="FAIL", launched=False, actual_wait=False,
                                   actual_return_code=None, error="preflight not completed"))
    try:
        inputs = [Path(tb), Path(image), Path(manifest_path), Path(__file__).resolve(), Path(tracefmt.__file__)]
        compile_record = Path(tb).parent / "Vventium_top__verFiles.dat"
        if compile_record.is_file():
            inputs.append(compile_record)
        for path in inputs:
            pins[str(path.resolve())] = digest(path)
        manifest = json.loads(Path(manifest_path).read_text())
        expected = manifest["exit_code"]
        cap = manifest["max_insn"]
        if (type(expected) is not int or not 0 < expected < 256 or not expected & 1
                or type(cap) is not int or cap <= 0 or manifest.get("exit_method") != "isa-debug-exit"
                or tracefmt.parse_hex(manifest.get("exit_port", "0")) != 0xf4
                or manifest.get("sys") is not True or Path(image).stat().st_size != manifest["image_bytes"]):
            raise ValueError("unsupported/malformed normal-system manifest")
        if not os.access(tb, os.X_OK):
            raise ValueError("native TB is not executable")
        active = subprocess.run([str(REPO / "tools/build_scope.sh"), "--is-active"],
                                pass_fds=lock_fds(), timeout=5).returncode
        if active:
            raise ValueError("native verification requires actual inherited build_scope")
        argv = [str(tb), "--image", str(image), "--system", "--cosim", "--out", str(out),
                "--max-insn", str(cap), "--quiesce", "400"]
        if faultlog:
            argv.append("+ven_faultlog")
        receipt = supervise(argv, stdout, stderr, receipt_path, wall_seconds)
        data = out.read_bytes()
        if not data or len(data) > LOG_LIMIT or not data.endswith(b"\n") or not stat.S_ISREG(out.lstat().st_mode):
            raise ValueError("missing/truncated/nonregular native trace")
        trace = tracefmt.read_trace(str(out))
        grade = grade_native(trace, stdout.read_text(), stderr.read_text(),
                             receipt["actual_return_code"], expected, cap)
        if any(digest(path) != sha for path, sha in pins.items()):
            raise ValueError("native input pin changed during run")
        receipt.update(result="PASS", manifest_expected_exit=expected, inputs=pins, inputs_stable=True,
                       trace_sha256=digest(out), **grade)
        save_receipt(receipt_path, receipt)
        return receipt
    except BaseException as exc:
        if receipt_path.is_file():
            receipt = json.loads(receipt_path.read_text())
            pin_errors = []
            for path, sha in pins.items():
                try:
                    if digest(path) != sha:
                        pin_errors.append(f"changed input: {path}")
                except OSError as pin_error:
                    pin_errors.append(f"unreadable input {path}: {pin_error}")
            receipt.update(result="FAIL", error=f"{type(exc).__name__}: {exc}", inputs=pins,
                           inputs_stable=not pin_errors, input_pin_errors=pin_errors)
            save_receipt(receipt_path, receipt)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("tb", "image", "manifest", "out", "stdout", "stderr"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--wall-seconds", type=float, default=90)
    parser.add_argument("--faultlog", action="store_true")
    args = parser.parse_args()
    try:
        receipt = run_native(args.tb, args.image, args.manifest, args.out, args.stdout, args.stderr,
                             args.wall_seconds, args.faultlog)
    except Exception as exc:
        sys.exit("NATIVE-SYSTEM-FAIL: " + str(exc))
    print("NATIVE-SYSTEM-OK: actual exit", receipt["actual_return_code"],
          "records", receipt["records"], "clocks", receipt["clocks"])


if __name__ == "__main__":
    main()
