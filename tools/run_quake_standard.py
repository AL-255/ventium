#!/usr/bin/env python3
"""Cold FreeDOS Quake timedemo, on private frozen inputs; no snapshots.

Run under a descendant-containing memory/task-limited supervisor. A fresh live
result only requests a graceful host stop; acceptance is checked again after
the simulator exits and closes its disk. A cycle/time cap is never a pass.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import stat
import subprocess
import threading
import time
import types

import check_quake_timedemo as gate


ROOT = Path(__file__).resolve().parents[1]
LOG_LIMIT = 64 * 1024 * 1024
PIPE_EXIT_GRACE = 1.0


class CapturedLog:
    """Continuously preserve merged child output on one fresh, held file FD.

    The child never writes the evidence file directly. Collection continues
    while the main thread performs bounded, potentially blocking FAT reads.
    Any collection or file-integrity failure is sticky; an intact final footer
    cannot turn a partial/rewritten log back into acceptance evidence.
    """

    def __init__(self, path, limit=LOG_LIMIT):
        if limit <= 0:
            raise ValueError("positive evidence log limit required")
        self.path, self.limit = Path(path), limit
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_EXCL |
                          os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        self.identity = os.fstat(self.fd)
        self.lock = threading.RLock()
        self.cancel = threading.Event()
        self.finished = threading.Event()
        self.thread = self.pipe = None
        self.error = None
        self.eof = False
        self.captured = self.written = 0
        self.sha = hashlib.sha256()
        try:
            self._identity()
        except BaseException:
            os.close(self.fd)
            self.fd = None
            raise

    def _fail(self, message):
        with self.lock:
            self.error = self.error or str(message)[:512]

    def _identity(self):
        held, named = os.fstat(self.fd), self.path.lstat()
        expected = (self.identity.st_dev, self.identity.st_ino)
        if (not stat.S_ISREG(held.st_mode) or not stat.S_ISREG(named.st_mode) or
                (held.st_dev, held.st_ino) != expected or
                (named.st_dev, named.st_ino) != expected or
                held.st_nlink != 1 or named.st_nlink != 1):
            raise ValueError("evidence log path/inode/link identity changed")
        if held.st_size != self.written or named.st_size != self.written:
            raise ValueError("evidence log truncated or externally extended")

    def _write(self, chunk):
        with self.lock:
            self.captured += len(chunk)
            self._identity()
            if self.captured > self.limit:
                raise ValueError(f"evidence log exceeded {self.limit}-byte budget")
            pending = memoryview(chunk)
            while pending:
                try:
                    count = os.write(self.fd, pending)
                except InterruptedError:
                    continue
                if not 0 < count <= len(pending):
                    raise OSError("evidence log write made no valid progress")
                self.sha.update(pending[:count])
                self.written += count
                pending = pending[count:]
            self._identity()

    def start(self, pipe):
        if self.thread is not None:
            raise ValueError("evidence collector already started")
        self.pipe = pipe
        self.thread = threading.Thread(target=self._collect, name="quake-log-collector")
        try:
            self.thread.start()
        except Exception as exc:
            self._fail("evidence collector could not start: " + str(exc))
            if self.thread.ident is None:
                self.thread = None
                pipe.close()
                self.finished.set()
            raise ValueError(self.error) from exc

    def _collect(self):
        try:
            with selectors.DefaultSelector() as selector:
                os.set_blocking(self.pipe.fileno(), False)
                selector.register(self.pipe, selectors.EVENT_READ)
                while not self.cancel.is_set():
                    for key, _ in selector.select(0.1):
                        try:
                            chunk = os.read(key.fd, min(65536, self.limit + 1 - self.captured))
                        except (InterruptedError, BlockingIOError):
                            continue
                        if not chunk:
                            with self.lock:
                                self._identity()
                                self.eof = True
                            return
                        self._write(chunk)
                raise ValueError("evidence collection cancelled before pipe EOF")
        except BaseException as exc:
            self._fail(exc)
        finally:
            try:
                self.pipe.close()
            except Exception as exc:
                self._fail("evidence pipe close failed: " + str(exc))
            finally:
                self.finished.set()

    def snapshot(self):
        """Read the held inode, never a replacement opened through its path."""
        try:
            with self.lock:
                if self.error:
                    raise ValueError(self.error)
                self._identity()
                data = bytearray()
                while len(data) < self.written:
                    chunk = os.pread(self.fd, min(65536, self.written - len(data)), len(data))
                    if not chunk:
                        raise ValueError("short evidence log read")
                    data.extend(chunk)
                self._identity()
                if hashlib.sha256(data).digest() != self.sha.digest():
                    raise ValueError("evidence log content changed after pipe capture")
                return bytes(data)
        except (OSError, ValueError) as exc:
            self._fail(exc)
            raise

    def finish(self, timeout=30):
        """Called only after actual child.wait; EOF is independently required."""
        if self.thread is None:
            raise ValueError("evidence collector was not started")
        self.thread.join(timeout)
        if self.thread.is_alive():
            self._fail("evidence pipe EOF missing after child wait")
            self.cancel.set()
            self.thread.join(1)
        if self.thread.is_alive():
            raise ValueError("evidence collector did not stop")
        try:
            if self.error or not self.eof or self.captured != self.written:
                raise ValueError(self.error or "incomplete evidence pipe capture")
            os.fsync(self.fd)
            return self.snapshot()
        except (OSError, ValueError) as exc:
            self._fail(exc)
            raise

    def receipt(self, *, actual_wait, returncode):
        return {"schema": 1, "actual_child_wait": actual_wait, "sim_returncode": returncode,
                "pipe_eof": self.eof, "captured_bytes": self.captured,
                "persisted_bytes": self.written, "sha256": self.sha.hexdigest(),
                "file_device": self.identity.st_dev, "file_inode": self.identity.st_ino,
                "byte_limit": self.limit, "sticky_error": self.error}

    def close(self):
        self.cancel.set()
        if self.thread is not None:
            self.thread.join(1)
            if self.thread.is_alive():
                raise ValueError("evidence collector did not close")
        if self.fd is not None:
            fd = self.fd
            self.fd = None
            try:
                os.close(fd)
            except OSError as exc:
                self._fail("evidence log close failed: " + str(exc))
                raise


def loaded_code_hash(function):
    code = getattr(function, "__code__", None)
    if not isinstance(code, types.CodeType):
        return None

    def definition(item):
        # marshal's reference flags can change when executing code temporarily
        # changes constants' reference counts. Serialize stable code attributes
        # instead, including nested comprehensions without object addresses.
        constants = [definition(value) if isinstance(value, types.CodeType) else repr(value)
                     for value in item.co_consts]
        return [item.co_code.hex(), item.co_names, item.co_varnames, item.co_freevars,
                item.co_cellvars, item.co_argcount, item.co_posonlyargcount,
                item.co_kwonlyargcount, item.co_flags, item.co_exceptiontable.hex(), constants]

    return hashlib.sha256(json.dumps(definition(code), separators=(",", ":")).encode()).hexdigest()


def archive_python_sources(out):
    """Archive observed source, without claiming it is the exact loaded text.

    Python may have loaded these modules before their files were edited. The
    function-code fingerprints separately identify the loaded run/check code;
    canonical-file before/after hashes are observations, not execution proofs.
    """
    archive = out / "python"
    archive.mkdir()
    result = {"schema": 1, "provenance": "observed source archive; not exact loaded-source proof",
              "sources": {}, "loaded_function_code_before": {
                  "runner.run": loaded_code_hash(run), "checker.check": loaded_code_hash(gate.check)}}
    for source in (Path(__file__).resolve(), Path(gate.__file__).resolve()):
        with source.open("rb") as stream:
            data = stream.read(1024 * 1024 + 1)
        if len(data) > 1024 * 1024:
            raise ValueError("Python source archive exceeded 1 MiB per file")
        digest = hashlib.sha256(data).hexdigest()
        target = archive / source.name
        with target.open("xb") as stream:
            if stream.write(data) != len(data):
                raise OSError("short Python source archive write")
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o400)
            identity = os.fstat(stream.fileno())
        named = target.lstat()
        if (not stat.S_ISREG(named.st_mode) or named.st_nlink != 1 or
                (named.st_dev, named.st_ino) != (identity.st_dev, identity.st_ino) or
                gate.digest(target) != digest or gate.digest(source) != digest):
            raise ValueError("Python source changed while archiving")
        result["sources"][source.name] = {"source": str(source), "archive": str(target),
            "sha256_before": digest, "archive_device": identity.st_dev, "archive_inode": identity.st_ino}
    return result


def close_python_sources(provenance):
    for record in provenance["sources"].values():
        archive = Path(record["archive"])
        identity = archive.lstat()
        if (not stat.S_ISREG(identity.st_mode) or identity.st_nlink != 1 or
                (identity.st_dev, identity.st_ino) != (record["archive_device"], record["archive_inode"]) or
                gate.digest(archive) != record["sha256_before"]):
            raise ValueError("Python source archive identity/content changed")
        record["archive_sha256_after"] = record["sha256_before"]
        try:
            record["source_sha256_after"] = gate.digest(record["source"])
        except OSError as exc:
            record["source_sha256_after"] = None
            record["source_after_error"] = str(exc)[:512]
        record["canonical_source_unchanged"] = record["source_sha256_after"] == record["sha256_before"]
    provenance["loaded_function_code_after"] = {
        "runner.run": loaded_code_hash(run), "checker.check": loaded_code_hash(gate.check)}
    if provenance["loaded_function_code_after"] != provenance["loaded_function_code_before"]:
        raise ValueError("loaded runner/checker function code changed")


def require_process_group_absent(pid):
    # The child owns a fresh session, but a reaped leader is not proof that a
    # descendant has closed its guest disk. Fail on an extant/unknown group;
    # the caller's descendant-containing supervisor owns any further cleanup.
    # Never kill a group after reaping its leader: the numeric ID could be reused.
    try:
        os.killpg(pid, 0)
    except ProcessLookupError:
        return
    except OSError as exc:
        raise ValueError("cannot prove simulator process group absent") from exc
    raise ValueError("simulator process group remains after actual child wait")


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
    out.mkdir(parents=True, mode=0o700)
    python_provenance = archive_python_sources(out)
    write_json(out / "python-provenance.json", python_provenance)
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
    # Optional inherited trace/profile paths can open arbitrary host files for
    # writing (VEN_PCTRACE uses fopen("w")). Never leak those hooks into the
    # supposedly private cold run; only these explicit platform inputs remain.
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("VEN_", "AO486_", "VTM_"))}
    environment.update(AO486_BIOS_DIR=str(rom), AO486_RTC_EPOCH="1789257600", FPGA_DDR="2")
    log_path = out / "run.log"
    started = time.monotonic()
    reason = None
    deadline = started + args.seconds
    capture = CapturedLog(log_path)
    process = None
    actual_wait = False
    group_absent = False
    returncode = None
    try:
        process = subprocess.Popen(command, cwd=ROOT / "ao486-sim",
                                   env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   bufsize=0, start_new_session=True)
        try:
            capture.start(process.stdout)
            write_json(out / "running.json", {"pid": process.pid, "cpu": args.cpu})
            print(f"START FreeDOS Quake demo1 pid={process.pid} cpu={args.cpu}", flush=True)
            next_probe = time.monotonic()
            early_eof_at = None
            while process.poll() is None:
                if capture.error and not reason:
                    reason = "evidence capture failed: " + capture.error
                    stop.write_text("evidence capture failed; preserve partial evidence\n")
                    deadline = min(deadline, time.monotonic() + 30)
                if capture.eof and early_eof_at is None:
                    # EOF often races normal process exit by a scheduler tick.
                    # It is not permission to keep running without evidence.
                    early_eof_at = time.monotonic()
                if early_eof_at is not None and time.monotonic() - early_eof_at >= PIPE_EXIT_GRACE:
                    reason = reason or "evidence pipe EOF before simulator exit"
                    stop.write_text("pipe EOF without simulator exit; not qualification\n")
                    deadline = min(deadline, time.monotonic())
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
                if not capture.error and time.monotonic() >= next_probe:
                    try:
                        engine_log = capture.snapshot()
                    except (OSError, ValueError) as exc:
                        reason = reason or "evidence capture failed: " + str(exc)
                        stop.write_text("evidence capture failed; preserve partial evidence\n")
                        deadline = min(deadline, time.monotonic() + 30)
                    else:
                        # The collector keeps draining while this live FAT
                        # observation blocks. Only the closed final check can
                        # qualify completion; live FAT races are advisory.
                        if gate.ENGINE_ERROR_RE.search(engine_log) or gate.GUEST_ERROR_RE.search(engine_log):
                            reason = reason or "terminal simulator/guest error"
                            stop.write_text("terminal error; preserve evidence\n")
                            deadline = min(deadline, time.monotonic() + 30)
                        else:
                            try:
                                observation = gate.check(disk, receipt, engine_log)
                                if observation["status"] == "OBSERVED_UNQUALIFIED":
                                    write_json(out / "observation.json", observation)
                                    stop.write_text("fresh timedemo observed; close disk for final checking\n")
                                    deadline = min(deadline, time.monotonic() + 30)
                            except gate.TerminalError as exc:
                                reason = reason or str(exc)
                                stop.write_text("terminal guest error observed; preserve evidence\n")
                                deadline = min(deadline, time.monotonic() + 30)
                            except (OSError, ValueError, subprocess.SubprocessError):
                                pass
                    next_probe = time.monotonic() + 15
                time.sleep(0.1)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            reason = reason or str(exc)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
            returncode = process.wait()
            actual_wait = True
        try:
            require_process_group_absent(process.pid)
            group_absent = True
            engine_log = capture.finish()
            if reason:
                raise ValueError(reason)
            result = gate.check(disk, receipt, engine_log,
                                stopped=True, returncode=returncode)
            if result["status"] != "PASS":
                result = {"status": "FAIL", "reason": "no completed timedemo", "closed_disk_check": result}
            # An external replacement/rewrite during the final FAT check must
            # not leave a PASS pointing at a different evidence file.
            capture.snapshot()
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            result = {"status": "FAIL", "reason": str(exc)}
        try:
            close_python_sources(python_provenance)
        except (OSError, ValueError) as exc:
            python_provenance["closure_error"] = str(exc)[:512]
            result = {"status": "FAIL", "reason": str(exc), "preceding_check": result}
        try:
            capture.close()
        except (OSError, ValueError) as exc:
            result = {"status": "FAIL", "reason": str(exc), "preceding_check": result}
        result.update(sim_returncode=returncode, elapsed_seconds=time.monotonic() - started,
                      log_capture=capture.receipt(actual_wait=actual_wait, returncode=returncode),
                      process_group_absent_after_wait=group_absent,
                      python_provenance="python-provenance.json")
        write_json(out / "python-provenance.json", python_provenance)
        write_json(out / "capture.json", result["log_capture"])
        write_json(out / "result.json", result)
        print(json.dumps(result), flush=True)
        return 0 if result["status"] == "PASS" else 2
    finally:
        capture.close()


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
