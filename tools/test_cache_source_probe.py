#!/usr/bin/env python3
"""Compile/run tiny cache-observer host stubs, never a DUT or Verilator model.

Use tools/build_scope.sh -- timeout --kill-after=5s 60s python3 -B
tools/test_cache_source_probe.py. Each child has a768MiB address-space cap;
compile/run deadlines45/5seconds and no parallel compiler fan-out.
"""
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def child_limits():
    cap = 768 * 1024 * 1024
    resource.setrlimit(resource.RLIMIT_AS, (cap, cap))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main():
    # Retain the tiny executable and exact receipt in permitted scratch.
    scratch = Path(tempfile.mkdtemp(prefix="ventium-cache-source-host.", dir="/tmp"))
    binary = scratch / "test_cache_source_probe"
    command = ["c++", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-O0",
               str(ROOT / "tools/test_cache_source_probe.cpp"), "-o", str(binary)]
    started = time.monotonic()
    compile_result = subprocess.run(command, text=True, capture_output=True,
                                    timeout=45, preexec_fn=child_limits)
    if compile_result.returncode:
        print(compile_result.stdout + compile_result.stderr, end="")
        raise SystemExit(compile_result.returncode)
    result = subprocess.run([str(binary)], text=True, capture_output=True,
                            timeout=5, preexec_fn=child_limits)
    print(result.stdout + result.stderr, end="")
    inputs = [ROOT / "ao486-sim/ven/cache_source_probe.h",
              ROOT / "ao486-sim/ven/l1_fill_probe.h",
              ROOT / "tools/test_cache_source_probe.cpp", Path(__file__).resolve()]
    receipt = {"host_only": True, "dut_run": False, "scratch": str(scratch),
               "command": command, "memory_limit_bytes": 768 * 1024 * 1024,
               "compile_timeout_seconds": 45, "run_timeout_seconds": 5,
               "wall_seconds": time.monotonic() - started,
               "compile_exit": compile_result.returncode, "test_exit": result.returncode,
               "stdout": result.stdout, "stderr": result.stderr,
               "input_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in inputs},
               "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    # The runtime receipt is scratch output, not a repository source edit.
    (scratch / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, sort_keys=True))
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
