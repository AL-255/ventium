#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Ventium M2S.5 — RTL-ONLY structural self-check for SMM / RSM.

This is the RTL-phase (Phase 2) analogue of psmm-selfcheck.py (which proves the
round-trip against qemu FREE-RUNNING via QMP).  The qemu-system gdbstub single-
step oracle MASKS SMI and has no SMM awareness, so a differential golden trace is
INFEASIBLE and is NOT fabricated (see README.md / manifest.json).  Instead, the
RTL implements the SMM mechanism (SMI# entry -> P5 SMRAM save-state map -> SMM
handler -> RSM restore -> resume) and self-checks it RTL-ONLY: we run the SAME
bare-metal psmm.bin on the Verilator TB in --system mode (the RTL recognises the
APIC self-IPI SMI source on the ICR write, exactly as qemu's APIC does, so no TB
poke is needed), then assert BOTH:

  (1) the trace records show the SMM round-trip:
        - SMI ENTRY: a retire whose CS selector == SMBASE>>4 (0x3000), CR0.PE
          cleared (and PG clear), with EIP entering at SMBASE+0x8000 (0x8000);
        - the SMM HANDLER ran in that SMM context (CS==0x3000);
        - RSM RESTORE: a following retire back in the mainline (CS==0x08), CR0.PE
          restored, the EBX state-intact witness (0x5A4D900D) intact, and the
          resume EIP back in the interrupted mainline (0x000Fxxxx);
  (2) the post-run physical memory + the P5 save-state map (read from the TB's
      --smm-dump) carry the round-trip evidence at the DOCUMENTED P5 offsets:
        - [0x2000] == 0x5A4D5A4D   handler ran (wrote its sentinel in SMM ctx)
        - [0x2004] == 0x52455421   mainline resumed after RSM ('RET!')
        - [0x2008] == 0x5A4D900D   EBX witness survived SMI/RSM (RSM restored GPRs)
        - SMBASE+0xFFFC (P5 off 0x7FFC) == saved CR0 (PE set) -> SMI# saved CR0
        - SMBASE+0xFFF0 (P5 off 0x7FF0) == saved EIP (resume EIP, mainline range)
        - SMBASE+0xFFDC (P5 off 0x7FDC) == saved EBX == 0x5A4D900D
        - SMBASE+0xFEF8 (P5 off 0x7EF8) == the SMBASE relocation slot (default)

This is the same SMM round-trip the qemu free-run check proves — here demonstrated
in the RTL at the P5 save-map offsets (qemu uses the P6 layout, so the save area
is not byte-comparable; the round-trip + the documented P5 offsets ARE the check).

Exit 0 on success, non-zero (with a diagnostic) on failure.

Usage: python3 psmm-rtl-selfcheck.py <tb_ventium> <image.bin> <repo_root>
"""
import json
import subprocess
import sys
import tempfile
import os

TB    = sys.argv[1]
IMG   = sys.argv[2]
REPO  = sys.argv[3]

SMBASE = 0x30000

fails = []


def check(name, cond, detail):
    print("  [%s] %s -- %s" % ("OK " if cond else "FAIL", name, detail))
    if not cond:
        fails.append(name)


with tempfile.TemporaryDirectory() as td:
    trace = os.path.join(td, "psmm.rtl.vtrace")
    dump  = os.path.join(td, "psmm.smm.json")
    # max-insn generous so the post-RSM mainline (the spin loop + the two resume
    # sentinels) all retire; quiesce generous for the boot icache fills.
    cmd = [TB, "--image", IMG, "--system", "--out", trace,
           "--smm-dump", dump, "--smbase", "0x%x" % SMBASE,
           "--max-insn", "12000", "--quiesce", "400"]
    r = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    if r.returncode != 0:
        print("FATAL: RTL TB exited %d" % r.returncode)
        sys.exit(1)

    # ---- (1) trace-record evidence of the SMM round-trip ------------------
    recs = []
    with open(trace) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            # the first .vtrace line is the header (no per-instruction fields);
            # keep only retire records (those carrying the CS selector).
            if "cs" in obj and "pc" in obj:
                recs.append(obj)

    def H(r, k):
        return int(r[k], 16)

    smbase_sel = (SMBASE >> 4) & 0xFFFF   # 0x3000

    # SMI entry: first record whose CS == SMBASE>>4 with CR0.PE cleared.
    entry_i = next((i for i, r in enumerate(recs)
                    if H(r, "cs") == smbase_sel and (H(r, "cr0") & 1) == 0), None)
    # RSM restore: the first record AFTER the SMM context returns to the mainline
    # CS (0x08) with CR0.PE set again and the EBX witness intact.
    rsm_i = None
    if entry_i is not None:
        for i in range(entry_i + 1, len(recs)):
            r = recs[i]
            if H(r, "cs") == 0x08 and (H(r, "cr0") & 1) == 1:
                rsm_i = i
                break

    print("RTL SMM / RSM structural self-check (trace records + save-map dump):")
    check("SMI# ENTRY: CPU entered SMM context",
          entry_i is not None,
          ("n=%d cs=%s cr0=%s (CS==SMBASE>>4=0x%04x, CR0.PE cleared)" %
           (recs[entry_i]["n"], recs[entry_i]["cs"], recs[entry_i]["cr0"], smbase_sel))
          if entry_i is not None else "no SMM-context (CS=0x3000, CR0.PE=0) record found")

    # the SMM handler EIP entry is SMBASE+0x8000 = 0x8000 (CS base = SMBASE).
    handler_i = next((i for i, r in enumerate(recs)
                      if H(r, "cs") == smbase_sel and H(r, "pc") == 0x8000), None)
    check("SMM HANDLER ran at SMBASE+0x8000 in SMM context",
          handler_i is not None,
          ("n=%d pc=%s cs=%s" % (recs[handler_i]["n"], recs[handler_i]["pc"],
                                 recs[handler_i]["cs"]))
          if handler_i is not None else "no record at pc=0x8000 in the SMM context")

    check("RSM restored mainline context + GPR witness",
          rsm_i is not None and H(recs[rsm_i], "ebx") == 0x5A4D900D,
          ("n=%d cs=%s cr0=%s ebx=%s (back to CS=0x08, CR0.PE set, EBX intact)" %
           (recs[rsm_i]["n"], recs[rsm_i]["cs"], recs[rsm_i]["cr0"], recs[rsm_i]["ebx"]))
          if rsm_i is not None else "no post-RSM mainline (CS=0x08, CR0.PE=1) record")

    # resume EIP back in the interrupted mainline (0x000Fxxxx) right after RSM.
    resume_ok = False
    resume_pc = None
    if rsm_i is not None:
        for i in range(rsm_i, min(len(recs), rsm_i + 4)):
            if 0xF0000 <= H(recs[i], "pc") <= 0xFFFFF:
                resume_ok = True
                resume_pc = recs[i]["pc"]
                break
    check("RSM resumed the interrupted mainline EIP",
          resume_ok,
          "resume pc=%s (in the mainline 0x000Fxxxx range)" % resume_pc
          if resume_ok else "no mainline-EIP record after RSM")

    # ---- (2) post-run memory + the P5 save-state map ----------------------
    with open(dump) as f:
        d = json.load(f)

    def D(k):
        return int(d[k], 16)

    check("handler sentinel [0x2000] (SMM handler ran)",
          D("sent_smm_ran") == 0x5A4D5A4D,
          "[0x2000]=%s (want 0x5A4D5A4D)" % d["sent_smm_ran"])
    check("resume sentinel [0x2004] (mainline resumed via RSM)",
          D("sent_resumed") == 0x52455421,
          "[0x2004]=%s (want 0x52455421 'RET!')" % d["sent_resumed"])
    check("state-intact sentinel [0x2008] (EBX survived SMI/RSM)",
          D("sent_intact") == 0x5A4D900D,
          "[0x2008]=%s (want 0x5A4D900D)" % d["sent_intact"])
    check("P5 save-map CR0 @ SMBASE+0xFFFC (off 0x7FFC)",
          (D("save_cr0") & 1) == 1,
          "save_cr0=%s (interrupted CR0, PE set)" % d["save_cr0"])
    check("P5 save-map EIP @ SMBASE+0xFFF0 (off 0x7FF0)",
          0xF0000 <= D("save_eip") <= 0xFFFFF,
          "save_eip=%s (resume EIP, mainline range)" % d["save_eip"])
    check("P5 save-map EBX @ SMBASE+0xFFDC (off 0x7FDC)",
          D("save_ebx") == 0x5A4D900D,
          "save_ebx=%s (the saved witness GPR)" % d["save_ebx"])
    check("P5 save-map CS sel @ SMBASE+0xFFAC (off 0x7FAC)",
          D("save_cs_sel") == 0x08,
          "save_cs_sel=%s (the interrupted mainline CS)" % d["save_cs_sel"])
    check("P5 save-map SMBASE slot @ SMBASE+0xFEF8 (off 0x7EF8)",
          D("save_smbase") == SMBASE,
          "save_smbase=%s (the relocation slot)" % d["save_smbase"])

if fails:
    print("\nSMM-RTL-SELFCHECK: FAIL (%s)" % ", ".join(fails))
    sys.exit(1)
print("\nSMM-RTL-SELFCHECK: PASS -- RTL SMI# -> P5 save-map -> SMM handler -> RSM "
      "-> resume round-trip proven structurally (RTL-only; differential golden "
      "documented INFEASIBLE + deferred, see README.md)")
