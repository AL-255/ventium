#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Ventium M2S.5 — STRUCTURAL self-check for the SMM / RSM demonstrator.

This is the PARTIAL-ORACLE substitute for a differential golden.  The
qemu-system-i386 GDB-stub single-step path masks SMI (SSTEP_NOIRQ masks
CPU_INTERRUPT_SMI) and has no SMM awareness, so gen_trace.py --system CANNOT
capture SMM entry / the handler / RSM.  Instead we run the image FREE-RUNNING
(SMI fires via the APIC self-IPI) and prove the SMM round-trip by reading the
post-run physical memory + the QEMU SMM save area via QMP:

  [0x2000] == 0x5A4D5A4D   the SMM handler RAN (wrote its sentinel in SMM ctx)
  [0x2004] == 0x52455421   the mainline RESUMED after RSM ('RET!')
  [0x2008] == 0x5A4D900D   the state-intact witness GPR (EBX) survived SMI/RSM
                           (proves RSM restored the interrupted GPR state)
  SMM save area @ SMBASE+0xFF00.. carries the saved EIP/EFLAGS/CR0 (QEMU P6
                           layout) -> SMI# saved the interrupted CPU state
  info registers SMM == 0   RSM completed; CPU back in normal mode

Exit 0 on success, non-zero (with a diagnostic) on failure.

Usage: python3 psmm-selfcheck.py <qemu-system-i386> <image.bin> [qmp_port]
"""
import socket, json, subprocess, sys, time

QSYS = sys.argv[1]
IMG  = sys.argv[2]
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 45790

# Launch FREE-RUNNING (no -S/-gdb): SMI fires via the APIC self-IPI.  No
# isa-debug-exit device, so the image's `out 0xf4` is a harmless no-op and the
# guest falls into its hlt loop -> the VM stays alive for the QMP memory readback.
cmd = [QSYS, "-display", "none", "-machine", "pc,smm=on", "-m", "32",
       "-qmp", "tcp:127.0.0.1:%d,server,nowait" % PORT, "-bios", IMG]
proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def qmp_connect(port, deadline):
    last = None
    while time.time() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=5)
            f = s.makefile("rwb")
            f.readline()  # greeting
            f.write(b'{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()
            return s, f
        except OSError as e:
            last = e
            time.sleep(0.2)
    raise RuntimeError("could not connect to QMP: %s" % last)


def hmc(f, line):
    f.write((json.dumps({"execute": "human-monitor-command",
                         "arguments": {"command-line": line}}) + "\n").encode())
    f.flush()
    while True:
        ln = f.readline()
        if not ln:
            return None
        r = json.loads(ln)
        if "return" in r:
            return r["return"]
        if "error" in r:
            raise RuntimeError("QMP error: %s" % r["error"])


def read_dword(f, addr):
    """Read one little-endian dword at a physical address via 'xp'."""
    out = hmc(f, "xp/1xw 0x%x" % addr)
    # output looks like:  000000000003fff0: 0x60000011
    tok = out.strip().split()[-1]
    return int(tok, 16)


fails = []
try:
    s, f = qmp_connect(PORT, time.time() + 15)
    # Give the guest a moment to run through real->protected, the SMI, and into
    # its hlt loop, then sample.
    time.sleep(2.0)

    smm_ran   = read_dword(f, 0x2000)
    resumed   = read_dword(f, 0x2004)
    intact    = read_dword(f, 0x2008)
    saved_eip = read_dword(f, 0x3fff0)   # QEMU P6 save area: EIP @ SMBASE+0xFFF0
    saved_efl = read_dword(f, 0x3fff4)   #                    EFLAGS @ +0xFFF4
    saved_cr0 = read_dword(f, 0x3fffc)   #                    CR0 @ +0xFFFC
    regs = hmc(f, "info registers")
    smm_line = next((l.strip() for l in regs.splitlines() if "SMM=" in l), "")

    def check(name, cond, detail):
        mark = "OK " if cond else "FAIL"
        print("  [%s] %s -- %s" % (mark, name, detail))
        if not cond:
            fails.append(name)

    print("SMM / RSM structural self-check (free-run + QMP memory readback):")
    check("SMM handler RAN",
          smm_ran == 0x5A4D5A4D,
          "[0x2000]=0x%08x (want 0x5A4D5A4D = SMM handler wrote its sentinel)" % smm_ran)
    check("mainline RESUMED after RSM",
          resumed == 0x52455421,
          "[0x2004]=0x%08x (want 0x52455421 'RET!' = control returned via RSM)" % resumed)
    check("RSM restored interrupted GPR state",
          intact == 0x5A4D900D,
          "[0x2008]=0x%08x (want 0x5A4D900D = EBX witness survived SMI/RSM)" % intact)
    check("SMI# saved CPU state to SMRAM",
          saved_cr0 == 0x60000011 and (saved_efl & ~0x2) == 0x4 and 0xf0000 <= saved_eip <= 0xfffff,
          "save area: EIP=0x%08x EFLAGS=0x%08x CR0=0x%08x (QEMU P6 layout @ SMBASE+0xFF00)"
          % (saved_eip, saved_efl, saved_cr0))
    check("RSM completed (CPU back in normal mode)",
          "SMM=0" in smm_line,
          "info registers: %s" % (smm_line or "(no SMM field)"))

    s.close()
finally:
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except Exception:
        proc.kill()

if fails:
    print("\nSMM-SELFCHECK: FAIL (%s)" % ", ".join(fails))
    sys.exit(1)
print("\nSMM-SELFCHECK: PASS -- SMI# -> save -> SMM handler -> RSM -> resume "
      "round-trip proven structurally (free-run; differential golden deferred, "
      "see README.md)")
