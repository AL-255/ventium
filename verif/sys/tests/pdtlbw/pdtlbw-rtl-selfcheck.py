#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Ventium task #102 — RTL-ONLY self-check for the data-store-under-paging micro-TLB
regression (pdtlbw).

The refs qemu-system-i386 oracle is un-buildable in this environment (it needs
python3-venv + root), so the formal verify-sys differential golden is BLOCKED.
Instead this test is SELF-CHECKING in the guest: the bare-metal image does a paged
store at one privilege/state, a hardware TASK SWITCH, then a read-back, and reports
PASS/FAIL through the isa-debug-exit AL value (qemu maps AL -> process status
((AL<<1)|1); the Ventium TB mirrors that). AL=0x42 -> status 133 PASS, 0x21 ->
status 67 FAIL.

IMPORTANT: the bug is +VEN_FE_PIPE-SPECIFIC (only the registered micro-TLB has the
re-registration window). Run this on a FE_PIPE-enabled TB (e.g. the KV260/SoC
l1axi_kv_dos_q build). A non-FE_PIPE TB does not exercise the path. The TB must be
run with --cosim so the port-0xf4 isa-debug-exit handshake is serviced.

Usage: python3 pdtlbw-rtl-selfcheck.py <tb_ventium> <image.bin>

Exit 0 on PASS (TB status 133), 1 otherwise (with a diagnostic).
"""
import os
import subprocess
import sys

if len(sys.argv) != 3:
    print("usage: pdtlbw-rtl-selfcheck.py <tb_ventium> <image.bin>")
    sys.exit(2)

TB, IMG = sys.argv[1], sys.argv[2]
if not (os.path.isfile(TB) and os.access(TB, os.X_OK)):
    print("FATAL: TB not found / not executable: %s" % TB)
    sys.exit(2)
if not os.path.isfile(IMG):
    print("FATAL: image not found: %s" % IMG)
    sys.exit(2)

cmd = [TB, "--system", "--cosim", "--l1-axi", "--image", IMG,
       "--no-trace", "--max-insn", "20000", "--quiesce", "3000"]
r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

PASS, FAIL = 133, 67
if r.returncode == PASS:
    print("pdtlbw RTL self-check: PASS (read-back == stored sentinel across the "
          "paged store + task switch; TB isa-debug-exit status 133)")
    sys.exit(0)
elif r.returncode == FAIL:
    print("pdtlbw RTL self-check: FAIL — the read-back did NOT match the stored "
          "sentinel (the data-store-under-paging micro-TLB bug is present; TB "
          "status 67)")
    sys.exit(1)
else:
    print("pdtlbw RTL self-check: INCONCLUSIVE — TB exited %d (expected 133 PASS "
          "or 67 FAIL). Is this a FE_PIPE-enabled TB run with --cosim?"
          % r.returncode)
    sys.exit(1)
