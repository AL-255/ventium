#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M2S.0 — generate + validate the SYSTEM-MODE golden trace.
#
# End-to-end demonstrator of the system-mode oracle (NO RTL — that starts at
# M2S.1).  Steps:
#   1. ensure qemu-system-i386 is built (build-qemu-system.sh, idempotent)
#   2. build the bare-metal protected-mode + paging test image (tests/pmode)
#   3. confirm the image runs to the isa-debug-exit under qemu-system-i386
#      (expected process exit status 133 = (0x42<<1)|1)
#   4. generate the system golden .vtrace with gen_trace.py --system
#   5. validate the .vtrace is well-formed (parse with tracefmt) AND that it
#      captures the real->protected (CR0.PE 0->1, CS change) and paging
#      (CR3 load, CR0.PG 0->1) transitions
#
# Usage: bash verif/sys/run-sys-golden.sh [TEST]   (TEST defaults to "pmode")
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYS="$REPO/verif/sys"
REFS="$REPO/ventium-refs/07-p5-emulation-harness"
QSYS="$REFS/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"

TEST="${1:-pmode}"
TDIR="$SYS/tests/$TEST"
OUTDIR="$REPO/build/sys"
PORT="${PORT:-41277}"
mkdir -p "$OUTDIR"

# Test-class membership lists (defined unconditionally so the step-7 SKIP-branch
# `elif` chain never references an unset var under `set -u`):
#   INTR_TESTS  — M2S.3 IDT-delivery tests (extra 5b delivery validation)
#   XPRIV_TESTS — M2S.4 cross-privilege tests (extra 5c cross-priv validation)
#   TASK_TESTS  — M2S.4 hardware-task-switch tests (extra 5d task-switch validation)
#   SMM_TESTS   — M2S.5 SMM/RSM PARTIAL-ORACLE tests (structural self-check, NO
#                 differential golden: the gdbstub single-step path masks SMI and
#                 has no SMM awareness, so the golden is infeasible and not faked)
INTR_TESTS="pintr pfault pde"
XPRIV_TESTS="pcpl"
TASK_TESTS="ptask"
SMM_TESTS="psmm"
#   V86_TESTS   — M7.2 virtual-8086-mode tests (extra 5e V86 validation: V86 entry
#                 EFLAGS.VM 0->1 + CPL 0->3, an IOPL-sensitive #GP delivery to the
#                 CPL0 monitor with the 9-word V86 frame + VM cleared, and the
#                 return). The RTL --system V86 diff lands in Implement (the V86 RTL
#                 delta is de-risk-specified, gated behind `v86` so it is INERT when
#                 EFLAGS.VM=0); until then this is golden self-diff + the 5e check.
V86_TESTS="pv86"

#   WITNESS_TESTS — REVIEW_Aug3 tests whose graded behaviour QEMU 8.2.2 does
#                 NOT implement, so a differential golden cannot encode it
#                 (like the standalone ioperm gate, but kept in this harness):
#                 the image runs to the exit under BOTH oracles (flows may
#                 diverge), the golden is generated + validated + self-diffed
#                 as usual (and 5f pins QEMU's deviant flow honestly), and the
#                 RTL side is graded by WITNESSES (faultlog + final-record
#                 GPRs) in step 7w instead of a trace diff.
WITNESS_TESTS="piretgp0 pselnull ptswflt pxwrapm pxdplan"

say(){ echo; echo "=== $* ==="; }

# --- 1. qemu-system-i386 (idempotent) ------------------------------------------
say "1. ensure qemu-system-i386 is built"
bash "$SYS/build-qemu-system.sh"
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing"; exit 1; }

# --- 2. build the bare-metal image ---------------------------------------------
say "2. build bare-metal test image: $TEST"
make -C "$TDIR" >/dev/null
IMG="$TDIR/$(grep -oP '"image":\s*"\K[^"]+' "$TDIR/manifest.json")"
[[ -f "$IMG" ]] || { echo "FATAL: image $IMG not built"; exit 1; }
echo "image: $IMG ($(stat -c%s "$IMG") bytes)"

# --- 3. confirm it runs to the isa-debug-exit ----------------------------------
say "3. confirm image runs to isa-debug-exit under qemu-system-i386"
EXPECT_EXIT="$(grep -oP '"exit_code":\s*\K[0-9]+' "$TDIR/manifest.json")"
set +e
timeout 20 "$QSYS" -display none -machine pc -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$IMG" >/dev/null 2>&1
RC=$?
set -e
echo "qemu exit status = $RC (expected $EXPECT_EXIT)"
[[ "$RC" == "$EXPECT_EXIT" ]] || { echo "FATAL: image did not reach the expected isa-debug-exit"; exit 1; }

# --- 3b. (M2S.5) SMM/RSM PARTIAL-ORACLE branch ---------------------------------
# psmm is a PARTIAL-ORACLE stage: the qemu-system gdbstub single-step path masks
# SMI (sstep_flags=SSTEP_NOIRQ masks CPU_INTERRUPT_SSTEP_MASK, which includes
# CPU_INTERRUPT_SMI) and has no SMM awareness, so gen_trace.py --system CANNOT
# capture SMM entry/handler/RSM and a differential golden is INFEASIBLE.  We do
# NOT fabricate one.  Instead:
#   (a) demonstrate the infeasibility honestly: a gdbstub single-step trace of
#       the image NEVER shows the SMM context (no jump to SMBASE+0x8000), then
#   (b) prove the SMM round-trip STRUCTURALLY by running the image FREE-RUNNING
#       (SMI fires via the APIC self-IPI) and reading the post-run physical
#       memory + the QEMU SMM save area via QMP (psmm-selfcheck.py).
# The RTL --system differential is DEFERRED to the RTL phase (RTL-only assertion
# test with SMI asserted in the TB; see README.md + manifest.json).
if echo " $SMM_TESTS " | grep -q " $TEST "; then
  say "3b. SMM/RSM PARTIAL-ORACLE: demonstrate golden INFEASIBILITY + structural self-check"

  # (a) honest infeasibility: single-step the image and confirm the gdbstub never
  #     observes the SMM context (no CS:EIP in the SMM handler at SMBASE+0x8000).
  echo "  (a) gdbstub single-step does NOT capture SMM (the golden infeasibility):"
  PROBE_OUT="$OUTDIR/$TEST.sys.vtrace.infeasible"
  MODE="$(grep -oP '"image_mode":\s*"\K[^"]+' "$TDIR/manifest.json")"
  # A short cap is enough: the ICR-write that would dispatch SMI retires within
  # the first ~60 single-steps, so 200 steps amply cross it. Under single-step
  # SMI is masked, so the SMM context never appears no matter how far we step.
  "$PY" "$GEN" --qemu "$QSYS" --system --image "$IMG" --image-mode "$MODE" \
      --out "$PROBE_OUT" --port "$PORT" --max-insn 200 >/dev/null 2>&1 || true
  # SMM entry would show CS selector reading SMBASE>>4 = 0x3000 or pc=0x00008000.
  # (grep -c prints 0 AND exits 1 when there are no matches; capture the printed
  # count only — do NOT append a second 0 via `|| echo`.)
  SMM_HITS="$(grep -cE '"cs":"0x3000"|"pc":"0x00008000"' "$PROBE_OUT" 2>/dev/null)" || true
  REC_CNT="$(grep -c '"n":' "$PROBE_OUT" 2>/dev/null)" || true
  echo "      single-step trace records:                 ${REC_CNT:-0}"
  echo "      records showing the SMM handler context:    $SMM_HITS  (expected 0 — SMI is masked under single-step)"
  [[ "$SMM_HITS" == "0" ]] || { echo "FATAL: unexpected SMM context in single-step trace (oracle assumption changed)"; exit 1; }
  echo "      CONFIRMED: gen_trace --system cannot trace SMM -> NO golden fabricated."

  # (b) structural self-check: free-run, prove the SMM round-trip via QMP.
  say "3c. SMM/RSM structural self-check (qemu free-run + QMP physical-memory readback)"
  SELF="$(grep -oP '"selfcheck":\s*"\K[^"]+' "$TDIR/manifest.json")"
  [[ -n "$SELF" && -f "$TDIR/$SELF" ]] || { echo "FATAL: selfcheck script $TDIR/$SELF missing"; exit 1; }
  "$PY" "$TDIR/$SELF" "$QSYS" "$IMG" "$((PORT + 500))"

  # (c) M2S.5 Phase 2 — the RTL SMM mechanism, self-checked RTL-ONLY. The RTL
  #     implements SMI# entry (P5 save-state map @ SMBASE+0x8000+offset; clear
  #     CR0 PE/PG/EM/TS; CS base=SMBASE sel=SMBASE>>4; EIP=0x8000; big limits),
  #     the SMM handler, and RSM (0F AA) restoring the full state + resuming. The
  #     RTL recognises the APIC self-IPI SMI source on the ICR write (exactly as
  #     qemu's APIC does), so the SAME bare-metal psmm.bin drives the RTL round-
  #     trip — NO TB poke, NO fabricated golden. The RTL trace + the save-map dump
  #     prove the round-trip at the DOCUMENTED P5 offsets (the gdbstub single-step
  #     oracle cannot trace SMM, so the differential golden stays INFEASIBLE +
  #     deferred — README.md). This is the RTL-only assertion test the spec calls
  #     for when the SMI oracle is infeasible.
  say "3d. SMM/RSM RTL-ONLY structural self-check (RTL trace + P5 save-map dump)"
  RTL_SELF="$(grep -oP '"selfcheck_rtl":\s*"\K[^"]+' "$TDIR/manifest.json")"
  [[ -n "$RTL_SELF" && -f "$TDIR/$RTL_SELF" ]] || { echo "FATAL: RTL selfcheck $TDIR/$RTL_SELF missing"; exit 1; }
  TB="${TB_BIN:-$REPO/verif/tb/obj_dir/tb_ventium}"
  [[ -n "${TB_BIN:-}" ]] || make -C "$REPO/verif/tb" rtl >/dev/null 2>&1
  [[ -x "$TB" ]] || { echo "FATAL: RTL TB $TB not built"; exit 1; }
  "$PY" "$TDIR/$RTL_SELF" "$TB" "$IMG" "$REPO"

  echo
  echo "SMM-PARTIAL-OK  (psmm: SMI#->save->SMM handler->RSM->resume proven"
  echo "                structurally BOTH ways — qemu free-run (QMP) AND the RTL"
  echo "                SMM mechanism (P5 save-map @ SMBASE+0xFE00, RTL-only); the"
  echo "                differential golden is documented INFEASIBLE + deferred —"
  echo "                see tests/psmm/README.md)"
  exit 0
fi

# --- 4. generate the system golden ---------------------------------------------
say "4. generate system golden trace (gen_trace.py --system)"
OUT="$OUTDIR/$TEST.sys.vtrace"
MAXI="$(grep -oP '"max_insn":\s*\K[0-9]+' "$TDIR/manifest.json")"
MODE="$(grep -oP '"image_mode":\s*"\K[^"]+' "$TDIR/manifest.json")"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$IMG" --image-mode "$MODE" \
    --out "$OUT" --port "$PORT" --max-insn "$MAXI"
echo "golden: $OUT ($(wc -l < "$OUT") lines)"

# --- 5. validate well-formed + transitions captured ----------------------------
say "5. validate the golden (.vtrace well-formed + transitions captured)"
PYTHONPATH="$REPO/verif/diff" "$PY" - "$OUT" <<'PYEOF'
import json, sys
import tracefmt as t
path = sys.argv[1]
tr = t.read_trace(path)
assert tr.mode == "func", "mode must be func"
assert tr.sys, "header must carry sys:true"
# well-formedness: every record has all func+sys fields at their declared width
need = ["pc"] + t.GPR_KEYS + ["eflags"] + t.SEG_KEYS + t.SYS_CR
for r in tr.records:
    for k in need:
        assert k in r, f"record n={r.get('n')} missing {k}"
        assert int(r[k], 16) < (1 << t._WIDTH[k]), f"{k} overflow in n={r['n']}"
ns = [r["n"] for r in tr.records]
assert ns == list(range(len(ns))), "n not strictly 0..N-1"

def H(r, k): return int(r[k], 16)
pe = pg = cr3 = csj = None
prev = None
for r in tr.records:
    if prev is not None:
        if (H(prev,"cr0")&1)==0 and (H(r,"cr0")&1)==1: pe = r
        if (H(prev,"cr0")>>31&1)==0 and (H(r,"cr0")>>31&1)==1: pg = r
        if H(prev,"cr3")!=H(r,"cr3"): cr3 = r
        if H(prev,"cs")!=H(r,"cs") and H(prev,"cs")==0xf000: csj = r
    prev = r

assert pe is not None, "CR0.PE 0->1 transition NOT captured"
assert csj is not None, "real->protected CS far-jump NOT captured"
print(f"  well-formed: {len(tr.records)} records, all func+sys fields valid, n=0..{len(ns)-1}")
print(f"  CR0.PE 0->1 : n={pe['n']} pc={pe['pc']} cr0->{pe['cr0']}")
print(f"  CS far-jump : n={csj['n']} pc={csj['pc']} cs 0xf000->{csj['cs']}")
if cr3 is not None:
    print(f"  CR3 load    : n={cr3['n']} pc={cr3['pc']} cr3->{cr3['cr3']}")
if pg is not None:
    print(f"  CR0.PG 0->1 : n={pg['n']} pc={pg['pc']} cr0->{pg['cr0']}")
else:
    print("  CR0.PG 0->1 : (paging not enabled in this test)")
print("  VALID: system golden is well-formed and captures the mode transitions")
PYEOF

# --- 5b. (M2S.3) IDT-delivery validation for the interrupt/fault tests ---------
# For pintr / pfault, additionally confirm the golden captures the IDT-DELIVERY
# sequence: a CS:EIP transfer INTO each installed gate's handler (read from the
# test ELF's symbol table), the in-handler IF state (interrupt gates clear IF;
# trap gates leave it), and the IRET RETURN of control to the mainline (a CS:EIP
# transfer back OUT of the handler region).  This is the Phase-1 evidence that the
# delivery -> frame-push -> handler -> IRET sequence is present in the golden; the
# RTL --system diff against it is wired in Phase 2 (this stays golden self-diff).
if echo " $INTR_TESTS " | grep -q " $TEST "; then
  say "5b. IDT-delivery validation (handler entry + IRET return captured)"
  ELF="$TDIR/$TEST.elf"
  [[ -f "$ELF" ]] || { echo "FATAL: $ELF missing (needed for handler symbols)"; exit 1; }
  SYMS="$(nm "$ELF" 2>/dev/null | grep -E '_handler$' || true)"
  [[ -n "$SYMS" ]] || { echo "FATAL: no *_handler symbols in $ELF"; exit 1; }
  PYTHONPATH="$REPO/verif/diff" SYMS="$SYMS" "$PY" - "$OUT" <<'PYEOF'
import json, os, sys
import tracefmt as t
tr = t.read_trace(sys.argv[1])
recs = tr.records
def H(r, k): return int(r[k], 16)

# handler offset -> name (flat code base 0 => symbol value == linear EIP)
handlers = {}
for line in os.environ["SYMS"].splitlines():
    p = line.split()
    if len(p) == 3 and p[2].endswith("_handler"):
        handlers[int(p[0], 16)] = p[2]
hi = sorted(handlers)
lo, h16 = hi[0], hi[-1] + 0x40          # the contiguous handler region
def in_handler(eip): return lo <= eip <= h16

found = []   # (name, enter_n, iret_return_n, if_in_handler)
recN = recs
for idx, r in enumerate(recN):
    eip = H(r, "pc")
    if eip in handlers and (idx == 0 or not in_handler(H(recN[idx-1], "pc"))):
        # delivery: control just entered a handler from outside the region
        name = handlers[eip]
        # IF state INSIDE the handler body (after the gate's IF handling) and the
        # IRET RETURN of control back to the mainline.  Sample the IF from a
        # settled handler-body record (a few in, past the entry transient) so the
        # interrupt-gate-clears-IF vs trap-gate-leaves-IF distinction is reported.
        if_in = None
        ret_n = None
        for j in range(idx + 1, min(len(recN), idx + 60)):
            ej = H(recN[j], "pc")
            # first settled handler-body record (past the entry transient, before
            # IRET pops the saved EFLAGS back) -> the gated IF the handler runs at
            if if_in is None and in_handler(ej):
                if_in = (H(recN[j], "eflags") >> 9) & 1
            # IRET return: control leaves the handler region back to mainline
            if not in_handler(ej):
                ret_n = recN[j]["n"]
                break
        found.append((name, r["n"], ret_n, if_in))

assert found, "no IDT delivery (handler entry) captured in the golden"
for name, en, rn, iff in found:
    assert rn is not None, f"{name}: entered at n={en} but no IRET return captured"
    print(f"  delivery: {name:>14}  enter n={en}  IRET-return n={rn}  IF-in-handler={iff}")
print(f"  VALID: {len(found)} IDT delivery+IRET sequence(s) captured "
      f"(gate read -> CS:EIP to handler -> handler -> IRET return)")
PYEOF
fi

# --- 5c. (M2S.4) CROSS-PRIVILEGE validation for the pcpl test ------------------
# For pcpl, additionally confirm the golden captures the cross-privilege machinery
# the M2S.4 stage adds on top of M2S.3 same-privilege delivery:
#   (1) a CPL TRANSITION DOWN to CPL3 (CS.RPL/CPL 0 -> 3) via the inter-priv IRET,
#   (2) a CROSS-PRIV interrupt DELIVERY (CPL 3 -> 0) whose SS:ESP SWITCHES to the
#       TSS.SS0:ESP0 stack (the larger 5-word frame), and
#   (3) the INTER-PRIV IRET RETURN back UP to CPL3 (CS.RPL/CPL 0 -> 3 again, SS:ESP
#       switched back to the CPL3 user stack).
# This is the Phase-1 evidence that the cross-priv delivery -> handler -> inter-priv
# IRET sequence is present in the golden; the RTL --system diff against it is wired
# in Phase 2 (this stays golden self-diff for now).
if echo " $XPRIV_TESTS " | grep -q " $TEST "; then
  say "5c. CROSS-PRIVILEGE validation (CPL switch + stack switch + inter-priv IRET)"
  PYTHONPATH="$REPO/verif/diff" "$PY" - "$OUT" <<'PYEOF'
import sys
import tracefmt as t
tr = t.read_trace(sys.argv[1])
recs = tr.records
def H(r, k): return int(r[k], 16)
def cpl(r): return H(r, "cs") & 3

# Walk the trace and record every CPL transition along with the SS:ESP at that
# point, so we can assert the three cross-priv events are present + ordered.
down = None     # CPL 0 -> 3 (transfer DOWN to the user task, inter-priv IRET)
deliver = None  # CPL 3 -> 0 (cross-priv interrupt delivery, SS:ESP <- TSS.SS0:ESP0)
ret_up = None   # CPL 0 -> 3 (inter-priv IRET return back to the user task)
prev = None
for r in recs:
    if prev is not None:
        pc, cc = cpl(prev), cpl(r)
        ss_sw = H(prev, "ss") != H(r, "ss")
        if pc == 0 and cc == 3 and down is None:
            down = (prev, r)
        elif pc == 3 and cc == 0 and down is not None and deliver is None:
            assert ss_sw, "cross-priv delivery did NOT switch SS (no stack switch)"
            deliver = (prev, r)
        elif pc == 0 and cc == 3 and deliver is not None and ret_up is None:
            assert ss_sw, "inter-priv IRET return did NOT switch SS back"
            ret_up = (prev, r)
    prev = r

assert down is not None,    "no CPL 0->3 transition (transfer DOWN to CPL3) captured"
assert deliver is not None, "no CPL 3->0 cross-priv interrupt DELIVERY captured"
assert ret_up is not None,  "no CPL 0->3 inter-priv IRET RETURN captured"

dp, dn = down
xp, xn = deliver
rp, rn = ret_up
# the delivery target SS must equal the transfer-source (CPL0) SS = TSS.SS0 stack,
# and its ESP must be DIFFERENT from the CPL3 ESP (i.e. it switched stacks).
assert H(xn, "ss") == H(dp, "ss"), "delivery SS != the CPL0 (TSS.SS0) data selector"
assert H(xn, "esp") != H(xp, "esp"), "delivery ESP did not move to the TSS stack"
# the inter-priv IRET return must restore the CPL3 SS:ESP the user task ran on.
assert H(rn, "ss") == H(dn, "ss"), "IRET-return SS != the CPL3 user data selector"
assert H(rn, "esp") == H(dn, "esp"), "IRET-return ESP != the CPL3 user stack ESP"

print(f"  CPL 0->3 (transfer DOWN)   : n={dn['n']} cs {dp['cs']}->{dn['cs']} "
      f"ss {dp['ss']}->{dn['ss']} esp->{dn['esp']}  (CPL{cpl(dp)}->{cpl(dn)})")
print(f"  CPL 3->0 (cross-priv INT)  : n={xn['n']} cs {xp['cs']}->{xn['cs']} "
      f"ss {xp['ss']}->{xn['ss']} esp->{xn['esp']}  (stack switch to TSS.SS0:ESP0)")
print(f"  CPL 0->3 (inter-priv IRET) : n={rn['n']} cs {rp['cs']}->{rn['cs']} "
      f"ss {rp['ss']}->{rn['ss']} esp->{rn['esp']}  (return back to CPL3)")
print("  VALID: cross-privilege CPL transition + TSS stack switch + the 5-word "
      "frame + inter-priv IRET return all captured in the golden")
PYEOF
fi

# --- 5d. (M2S.4 STRETCH) HARDWARE TASK SWITCH validation for the ptask test ----
# For ptask, confirm the golden captures the hardware task switch: a far JMP to a
# TSS selector that (1) RELOADS the incoming task GPR/ESP state from the new TSS
# (the GPRs/ESP take the pre-initialised TSS2 image values across the CS:EIP jump
# to task2) and (2) SAVED the outgoing task state into the current TSS (task2
# reads TSS1.EIP/TSS1.EAX back as nonzero / the live value).  This is the Phase-1
# evidence of the save+load task switch; the RTL --system diff is Phase 2.
if echo " $TASK_TESTS " | grep -q " $TEST "; then
  say "5d. HARDWARE TASK SWITCH validation (state save + state reload across JMP)"
  PYTHONPATH="$REPO/verif/diff" "$PY" - "$OUT" <<'PYEOF'
import sys
import tracefmt as t
tr = t.read_trace(sys.argv[1])
recs = tr.records
def H(r, k): return int(r[k], 16)

# The TSS2 incoming image programmed by the test: EAX=0xAAAAAAAA, EBX=0xBBBBBBBB,
# ESP=0x00070000.  Find the record where ALL THREE appear together at once for the
# first time -- that is the post-task-switch state (the GPRs reloaded from TSS2).
sw = None
for i, r in enumerate(recs):
    if H(r,"eax")==0xAAAAAAAA and H(r,"ebx")==0xBBBBBBBB and H(r,"esp")==0x00070000:
        sw = (recs[i-1] if i else None, r)
        break
assert sw is not None, ("no hardware-task-switch GPR reload captured "
                        "(EAX=0xAAAAAAAA, EBX=0xBBBBBBBB, ESP=0x00070000 from TSS2)")
prev, cur = sw
# the busy-bit toggle proof EDI=0x898B (TSS1 available 0x89, TSS2 busy 0x8B) must
# appear later in the incoming task (proof the JMP toggled the descriptor busy bits).
busy = next((r for r in recs if H(r,"edi")==0x898B), None)
# the outgoing-save proof: a nonzero TSS1.EIP read back into EDX (the CPU wrote the
# resume EIP into TSS1 during the save) -- captured as EDX in the 0x000fxxxx range.
saved = next((r for r in recs if 0x000f0000 <= H(r,"edx") <= 0x000fffff), None)

print(f"  TASK SWITCH (state reload) : n={cur['n']} pc={cur['pc']} "
      f"eax={cur['eax']} ebx={cur['ebx']} esp={cur['esp']}  "
      f"(GPR/ESP image loaded from the incoming TSS2)")
assert saved is not None, "no outgoing state SAVE captured (TSS1.EIP read-back)"
print(f"  outgoing STATE SAVE proof  : n={saved['n']} edx={saved['edx']} "
      f"(task1 resume EIP saved into TSS1 by the switch)")
assert busy is not None, "no busy-bit toggle captured (EDI=0x898B)"
print(f"  BUSY-bit toggle proof      : n={busy['n']} edi={busy['edi']} "
      f"(TSS1 access 0x89 available, TSS2 access 0x8B busy)")
print("  VALID: hardware task switch (outgoing state save + incoming state load "
      "+ busy-bit toggle) captured in the golden")
PYEOF
fi

# --- 5e. (M7.2) VIRTUAL-8086 MODE validation for the pv86 test -----------------
# For pv86, additionally confirm the golden captures the V86 machinery the M7.2
# stage adds:
#   (1) V86 ENTRY: an IRET into V86 sets EFLAGS.VM 0->1, transfers CS:EIP into the
#       V86 task (CS becomes the V86 segment 0x1000), and forces CPL 0 -> 3, with
#       paging still live (CR0.PG stays 1).
#   (2) an IOPL-SENSITIVE #GP DELIVERY from V86 to the CPL0 monitor: EFLAGS.VM
#       1->0 (cleared on entry), CPL 3->0, the SS:ESP switches to the TSS.SS0:ESP0
#       monitor stack (the 9-word V86 frame), and CS becomes the monitor code 0x08.
#   (3) the RETURN: the monitor IRETs back into V86 (EFLAGS.VM 0->1 again, CPL
#       0->3), and control resumes in the V86 task.
# This is the Phase-1 evidence that the V86 entry -> IOPL #GP -> 9-word frame ->
# monitor -> IRET-back sequence is present in the golden; the RTL --system V86 diff
# is wired in Implement (the V86 RTL delta is de-risk-specified, gated behind `v86`
# so it is INERT when EFLAGS.VM=0 -> all prior sys gates stay byte-identical).
if echo " $V86_TESTS " | grep -q " $TEST "; then
  say "5e. VIRTUAL-8086 validation (V86 entry VM 0->1 + IOPL #GP to the monitor + return)"
  PYTHONPATH="$REPO/verif/diff" "$PY" - "$OUT" <<'PYEOF'
import sys
import tracefmt as t
tr = t.read_trace(sys.argv[1])
recs = tr.records
def H(r, k): return int(r[k], 16)
def vm(r):  return (H(r, "eflags") >> 17) & 1     # EFLAGS.VM (bit17)
def pg(r):  return (H(r, "cr0") >> 31) & 1
# In V86 mode the CPL is architecturally 3 but the CS selector is a real-mode
# segment value (e.g. 0x1000), so `cs & 3` is NOT the CPL.  EFLAGS.VM is the
# privilege signal the trace carries: VM=1 => running in V86 (effective CPL3);
# VM=0 with the monitor's flat CS 0x08 (RPL0) => CPL0.  We label "priv" by VM.
def in_v86(r): return vm(r) == 1
def at_cpl0(r): return vm(r) == 0 and (H(r, "cs") & 3) == 0

# Walk the trace and find, in order:
#   entry:   VM 0->1   (the IRET into the V86 task)
#   deliver: VM 1->0   (an IOPL-sensitive #GP from V86 to the CPL0 monitor)
#   ret:     VM 0->1   (the monitor IRETs back into V86)
entry = deliver = ret = None
prev = None
for r in recs:
    if prev is not None:
        if vm(prev) == 0 and vm(r) == 1:
            if entry is None:
                entry = (prev, r)
            elif deliver is not None and ret is None:
                ret = (prev, r)
        elif vm(prev) == 1 and vm(r) == 0:
            if entry is not None and deliver is None:
                deliver = (prev, r)
    prev = r

assert entry is not None,   "no V86 ENTRY captured (EFLAGS.VM 0->1)"
assert deliver is not None, "no IOPL-sensitive #GP delivery from V86 captured (EFLAGS.VM 1->0)"

ep, en = entry
xp, xn = deliver
# V86 entry: VM must be set (effective CPL3) and paging must stay enabled (V86 is
# PE=1/PG=1).  The CS becomes the V86 segment (here 0x1000) — a real-mode-style
# selector, not a GDT selector.
assert in_v86(en), "V86 entry did not set EFLAGS.VM (not in V86)"
assert pg(en) == 1,  "paging not live at V86 entry (V86 must be PG=1)"
# Delivery: from V86 (VM=1) to the CPL0 monitor (VM=0, flat CS 0x08 RPL0); a #GP
# into the monitor switches to the TSS.SS0 stack, so SS must change (9-word frame).
assert in_v86(xp), "delivery source was not in V86 (VM=1)"
assert at_cpl0(xn), "delivery target was not the CPL0 monitor (VM=0, CS RPL0)"
assert H(xp, "ss") != H(xn, "ss"), "V86->monitor delivery did not switch SS (no TSS stack switch)"

print(f"  V86 ENTRY (VM 0->1)        : n={en['n']} cs {ep['cs']}->{en['cs']} "
      f"eip->{en['pc']} eflags {ep['eflags']}->{en['eflags']}  "
      f"(VM {vm(ep)}->{vm(en)} => CPL3, PG={pg(en)})")
print(f"  IOPL #GP (VM 1->0, deliver): n={xn['n']} cs {xp['cs']}->{xn['cs']} "
      f"ss {xp['ss']}->{xn['ss']} eflags {xp['eflags']}->{xn['eflags']}  "
      f"(VM {vm(xp)}->{vm(xn)} => CPL3->0, 9-word V86 frame on TSS.SS0:ESP0, VM cleared)")
if ret is not None:
    rp, rn = ret
    assert in_v86(rn), "monitor IRET did not return to V86 (VM=1)"
    print(f"  RETURN  (VM 0->1, IRET)    : n={rn['n']} cs {rp['cs']}->{rn['cs']} "
          f"eflags {rp['eflags']}->{rn['eflags']}  (VM {vm(rp)}->{vm(rn)}, back into V86)")
else:
    print("  RETURN  (VM 0->1, IRET)    : (the FIRST IOPL op also terminated; "
          "see the success proof) ")

# Count all the IOPL-sensitive #GP deliveries from V86 (every VM 1->0 transition
# into the CPL0 monitor).
ngp = sum(1 for i in range(1, len(recs))
          if vm(recs[i-1]) == 1 and at_cpl0(recs[i]))
print(f"  IOPL-sensitive #GP deliveries from V86 captured: {ngp} "
      f"(CLI/STI/PUSHF/POPF/INT 0x21/INT 0x20 at IOPL<3)")
assert ngp >= 1, "expected at least one IOPL-sensitive #GP from V86"
print("  VALID: V86 entry (VM 0->1, CPL 0->3, PG live) + IOPL-sensitive #GP "
      "delivery to the CPL0 monitor (9-word frame, VM cleared) + return all "
      "captured in the golden")
PYEOF
fi

# --- 5f. (REVIEW_Aug3 C-02/C-04 + REVIEW1_Aug3 R2) witness validation ------
# For the REVIEW_Aug3 regression tests, confirm the GOLDEN actually captures the
# witness values the finding is graded on (not merely that it runs to the exit):
#   pcalltss  (C-04): NT set somewhere in task2, and the exit record carries
#             edi=0x20 (back-link) + ecx=0x8B8B (both descriptors busy).
#   ptaskpg   (C-02): a record with cs=0x000C (the TI=1 incoming CS from the
#             incoming LDT2 actually runs) and the exit record carries
#             edi=0x898B (busy toggle read back THROUGH paging).
#   pretfoutpg(C-02/H-02): the exit record carries edi=0x0C060023 (case-1 outer
#             SS), esi=0x00004FF0 (case-2 16-bit outer SP zero-extended).
#   pjmpgate  (C-04): the #GP delivery (vector handler entry), a record with
#             cs=0x003B (conforming JMP keeps CPL: RPL forced to 3), and the
#             exit record carries edi=13 (vector) + esi=0x28 (gate selector).
#   pltr      (H-11b): the exit record carries edi=0x8B (LTR busy byte),
#             esi=13 (second-LTR #GP vector), ebp=0x18 (error code), ecx=0
#             (sldt after null lldt), ebx=0xC0C0C0C0 (no-#PF sentinel).
#   pretfres  (H-02): the exit record carries edi=0x000B000B (two #NP),
#             esi=0x00280030 (error codes), ebp=0x00180014 (ESP gaps 24/20),
#             ebx=0x23 + ecx=0x00004FF0 (16-bit outer SS + zero-extended ESP).
#   piopermwrap (M-01): the exit record carries ecx=3 (#GPs: two wraps + the
#             set-bit control), esi=3 (zero error codes), ebx=2 (permitted).
#   piretgp0  (H-03 WITNESS gate): asserts the GOLDEN pins QEMU's deviant flow
#             honestly (oracle gap 1: QEMU runs past the limit, so esi=ecx=0)
#             plus the oracle-identical witnesses (edi=0xA1A1A1A1, the case-B
#             segment boundary ebp=0x002B0000, ebx=0x00300020).
#   pxfer     (REVIEW1_Aug3 R2-C01): a record with cs=0x0068 (the ACCEPTED
#             conforming-JMP control ran) and the exit record carries
#             edi=0x0004000F (four #NP + fifteen #GP), esi=0x00010914 (case-4
#             err 0x0004 TI-preserved + 9 descriptor access bytes clean + all
#             20 rejects ESP-preserving),
#             ebp=0x00008989 (rejected TSS transfers wrote no busy byte),
#             ebx=0x0000898B (the ACCEPTED switch toggled them),
#             ecx=0x00080080 (case-1/case-12 error codes).
#   pselnull  (REVIEW1_Aug3 R2-C02 WITNESS gate): the oracle-identical
#             witnesses (edi=ecx=0x0BABE001, esi=0x00010004) plus an HONEST pin
#             of QEMU's deviant case-D flow (oracle gap 1: QEMU raises the
#             incoming-LDTR #TS only AFTER committing the switch, so
#             ebp=0x000A0004 with d_espok=0 and ebx=0x00008B89 with both busy
#             bytes toggled).
#   pxc04*    (REVIEW1_Aug3 R2-C03): the six ex-xc04 reachability probes,
#             converted to CORRECTNESS gates for the generic page-crossing
#             fragment engine. Each proves its producer's crossing access
#             completes with architecturally correct results across two
#             NON-CONTIGUOUS physical frames (wrong-frame accesses return
#             poison), and the write producers (f/e) additionally prove the
#             probe-before-commit atomicity (page 1 untouched when page 2
#             rejects). Per-test exit-record witnesses are listed with each
#             branch below.
#   pxwalkd   (REVIEW_Aug4 A4-C01): the crossing-store page-2 PROBE walks with
#             walk_is_write=1 but walk_set_dirty=0: a clean-leaf probe (PTE
#             P|RW|A, D=0, cold DTLB) must still fill the TLB so the store
#             completes (pre-fix: infinite walk loop), the probe's A-bit
#             writeback must NOT write D (checked with `test`-only witnesses
#             because the A bit itself is an oracle gap -- QEMU faults on its
#             page-1 lookup before ever probing page 2), the probe's
#             permission fault must carry W/R=1, and the 4 MiB PSE leaf
#             behaves the same. Per-test exit-record witnesses below.
#   ptswflt   (WITNESS gate): task-switch PHASE fault injection (docs/
#             tsw-phase-model.md). The GOLDEN pins QEMU's honest switch_tss_ra
#             flow: post-commit LDTR/segment validation (espok=0 halves in
#             ebp/ebx/ecx), the outgoing save absent for the incoming-read
#             fault (esi=0x0000A01C), QEMU's busy order (edx=0x14E300F4: the
#             outgoing clear before the save for JMP, the back-link before the
#             incoming busy-set for CALL). The vectors/error codes match the
#             RTL case for case -- #NP for a presence-only incoming-segment
#             failure, #TS when the type/privilege checks fire first.
AUG3_TESTS="pcalltss ptaskpg pretfoutpg pjmpgate pltr pretfres piopermwrap piretgp0 pxfer pselnull pxc04 pxc04i pxc04f pxc04e pxc04t pxc04m pxwalkd pjmpoff pdescprec pint16f psamepf ptswflt pxwrap pxwrapm pxfrag pxdplan"
if echo " $AUG3_TESTS " | grep -q " $TEST "; then
  say "5f. REVIEW_Aug3 + REVIEW1_Aug3 R2 witness validation (golden captures the fix's witnesses)"
  PYTHONPATH="$REPO/verif/diff" TEST="$TEST" "$PY" - "$OUT" <<'PYEOF'
import os, sys
import tracefmt as t
tr = t.read_trace(sys.argv[1])
recs = tr.records
def H(r, k): return int(r[k], 16)
test = os.environ["TEST"]
last = recs[-1]

if test == "pcalltss":
    nt = next((r for r in recs if H(r, "eflags") & 0x4000), None)
    assert nt is not None, "no NT-set record (the CALL did not set NT in the incoming image)"
    print(f"  NT in incoming image      : n={nt['n']} eflags={nt['eflags']} (task2 runs with EFLAGS.NT set)")
    assert H(last, "edi") == 0x20,   f"exit edi={last['edi']} != 0x20 (back-link = outgoing TR selector)"
    assert H(last, "ecx") == 0x8B8B, f"exit ecx={last['ecx']} != 0x8B8B (BOTH descriptors busy after the CALL)"
    assert H(last, "esi") == 0x1A1A1A1A, f"exit esi={last['esi']} != 0x1A1A1A1A (outgoing GPR save)"
    print(f"  exit witnesses            : edi=0x20 (back-link), ecx=0x8B8B (both busy), esi=0x1A1A1A1A (saved EAX)")
elif test == "ptaskpg":
    ldtcs = next((r for r in recs if H(r, "cs") == 0x000C), None)
    assert ldtcs is not None, "no record with cs=0x000C (the TI=1 incoming CS from the incoming LDT2 never ran)"
    print(f"  TI=1 incoming CS runs     : n={ldtcs['n']} cs=0x000C (resolved through the INCOMING LDT2)")
    assert H(last, "edi") == 0x898B,     f"exit edi={last['edi']} != 0x898B (busy toggle through paging)"
    assert H(last, "esi") == 0x1A1A1A1A, f"exit esi={last['esi']} != 0x1A1A1A1A (outgoing save on phys 0x801028)"
    print(f"  exit witnesses            : edi=0x898B (busy bytes on phys 0x810005/0x81000D), esi=0x1A1A1A1A")
elif test == "pretfoutpg":
    assert H(last, "edi") == 0x0C060023, f"exit edi={last['edi']} != 0x0C060023 (case-1 outer SS)"
    assert H(last, "ebp") == 0x00402FF0, f"exit ebp={last['ebp']} != 0x00402FF0 (case-1 outer ESP, phys 0x810000)"
    assert H(last, "ebx") == 0x80808080, f"exit ebx={last['ebx']} != 0x80808080 (int 0x80 handler sentinel)"
    assert H(last, "esi") == 0x16060023, f"exit esi={last['esi']} != 0x16060023 (case-2 outer SS)"
    assert H(last, "ecx") == 0x00004FF0, f"exit ecx={last['ecx']} != 0x00004FF0 (case-2 16-bit SP zero-extended; H-02)"
    print(f"  exit witnesses            : edi=0x0C060023 ebp=0x00402FF0 ebx=0x80808080 esi=0x16060023 ecx=0x00004FF0")
    print(f"                            (32-bit + 16-bit outer RETF, non-identity pages, H-02 zero-extension)")
elif test == "pjmpgate":
    conf = next((r for r in recs if H(r, "cs") == 0x003B), None)
    assert conf is not None, "no record with cs=0x003B (conforming JMP did not keep CPL: CS.RPL != 3)"
    print(f"  conforming JMP keeps CPL  : n={conf['n']} cs=0x003B (RPL forced to the kept CPL=3)")
    assert H(last, "edi") == 0x0D, f"exit edi={last['edi']} != 13 (#GP vector for the JMP-to-nonconforming case)"
    assert H(last, "esi") == 0x08, f"exit esi={last['esi']} != 0x08 (#GP error code = the TARGET selector)"
    assert H(last, "ebp") == 0x10, f"exit ebp={last['ebp']} != 0x10 (call-gate callee ran on the TSS stack)"
    assert H(last, "ebx") == 0xBBBBBBBB, f"exit ebx={last['ebx']} != 0xBBBBBBBB (the far CALL returned via the frame)"
    print(f"  exit witnesses            : edi=13 (#GP vector), esi=0x08 (target selector), ebp=0x10 (TSS SS0)")
elif test == "pltr":
    assert H(last, "edi") == 0x8B,       f"exit edi={last['edi']} != 0x8B (LTR busy byte: type 9 -> B at descriptor+5 BEFORE TR commits)"
    assert H(last, "esi") == 13,         f"exit esi={last['esi']} != 13 (second LTR on the busy descriptor must #GP)"
    assert H(last, "ebp") == 0x18,       f"exit ebp={last['ebp']} != 0x18 (#GP error code = sel & 0xFFFC)"
    assert H(last, "ecx") == 0,          f"exit ecx={last['ecx']} != 0 (sldt after the null lldt)"
    assert H(last, "ebx") == 0xC0C0C0C0, f"exit ebx={last['ebx']} != 0xC0C0C0C0 (null lldt with GDT[0] non-present raised NO #PF)"
    print(f"  exit witnesses            : edi=0x8B (busy byte), esi=13 ebp=0x18 (re-LTR #GP), ecx=0 (sldt), ebx=0xC0C0C0C0 (no #PF)")
elif test == "pretfres":
    assert H(last, "edi") == 0x000B000B, f"exit edi={last['edi']} != 0x000B000B (both rejected RETFs delivered #NP)"
    assert H(last, "esi") == 0x00280030, f"exit esi={last['esi']} != 0x00280030 (error codes = the popped selectors)"
    assert H(last, "ebp") == 0x00180014, f"exit ebp={last['ebp']} != 0x00180014 (ESP gaps 24/20: ESP preserved across the faults; H-02 restartability)"
    assert H(last, "ebx") == 0x23,       f"exit ebx={last['ebx']} != 0x23 (16-bit outer SS)"
    assert H(last, "ecx") == 0x00004FF0, f"exit ecx={last['ecx']} != 0x00004FF0 (16-bit outer SP zero-extended; H-02)"
    print(f"  exit witnesses            : edi=0x000B000B (two #NP), esi=0x00280030 (err codes), ebp=0x00180014 (gaps 24/20), ebx=0x23 ecx=0x4FF0 (outer SS/ESP)")
elif test == "piopermwrap":
    assert H(last, "ecx") == 3, f"exit ecx={last['ecx']} != 3 (#GPs: word @0xFFFF + dword @0xFFFD wraps + byte @0xFFF0 set bit)"
    assert H(last, "esi") == 3, f"exit esi={last['esi']} != 3 (every denial carried error code 0)"
    assert H(last, "ebx") == 2, f"exit ebx={last['ebx']} != 2 (permitted: byte @0xFFFF + dword @0xFFFC boundary)"
    print(f"  exit witnesses            : ecx=3 (#GPs incl. both wraps), esi=3 (err==0), ebx=2 (permitted)")
elif test == "piretgp0":
    # WITNESS gate (oracle gap 1): the GOLDEN pins QEMU's deviant flow -- QEMU
    # has no return-EIP-vs-limit check, so its run takes NO #GP (esi=ecx=0)
    # while the A1 + case-B witnesses, which every oracle agrees on, are present.
    assert H(last, "edi") == 0xA1A1A1A1, f"exit edi={last['edi']} != 0xA1A1A1A1 (A1: at-limit IRET succeeded)"
    assert H(last, "esi") == 0,          f"exit esi={last['esi']} != 0 (QEMU faults on NOTHING past the limit -- oracle gap 1, pinned honestly)"
    assert H(last, "ecx") == 0,          f"exit ecx={last['ecx']} != 0 (QEMU: no ESP-preservation events)"
    assert H(last, "ebp") == 0x002B0000, f"exit ebp={last['ebp']} != 0x002B0000 (case B: DS 0x2B survived, ES nulled -- all oracles)"
    assert H(last, "ebx") == 0x00300020, f"exit ebx={last['ebx']} != 0x00300020 (case B: FS conforming + GS DPL3/RPL0 survived -- all oracles)"
    print(f"  exit witnesses (QEMU flow): edi=0xA1A1A1A1 (A1), esi=ecx=0 (no return-limit check -- oracle gap 1), ebp=0x002B0000 ebx=0x00300020 (case-B boundary)")
    print(f"                            : the RTL-side witnesses (esi=0x00020002, ecx=2) are graded in step 7w")
elif test == "pxfer":
    conf = next((r for r in recs if H(r, "cs") == 0x0068), None)
    assert conf is not None, "no record with cs=0x0068 (the ACCEPTED conforming-JMP control, case 8, never ran)"
    print(f"  ACCEPTED conforming JMP   : n={conf['n']} cs=0x0068 (case 8: the validator is not a blanket reject)")
    assert H(last, "edi") == 0x0004000F, f"exit edi={last['edi']} != 0x0004000F (four #NP + fifteen #GP)"
    assert H(last, "esi") == 0x00010914, f"exit esi={last['esi']} != 0x00010914 (case-4 err 0x0004 TI-preserved + 9 descriptor access bytes clean + 20 ESP-preserving rejects)"
    assert H(last, "ebp") == 0x00008989, f"exit ebp={last['ebp']} != 0x00008989 (TSS_A/TSS_C busy bytes UNTOUCHED by the rejected transfers)"
    assert H(last, "ebx") == 0x0000898B, f"exit ebx={last['ebx']} != 0x0000898B (the ACCEPTED case-10 switch toggled TSS1 0x8B->0x89, TSS2 0x89->0x8B)"
    assert H(last, "ecx") == 0x00080080, f"exit ecx={last['ecx']} != 0x00080080 (case-1/case-12 error codes)"
    print(f"  exit witnesses            : edi=0x0004000F (4x#NP+15x#GP), esi=0x00010914 (c4 err 0x0004 + 9 desc bytes clean + ESP kept),")
    print(f"                              ebp=0x00008989 (no busy writes), ebx=0x0000898B (accepted toggle), ecx=0x00080080")
elif test == "pselnull":
    # WITNESS gate (oracle gap 1): the GOLDEN pins QEMU's deviant case-D flow
    # honestly -- QEMU raises the incoming-LDTR #TS(0x0004) only AFTER
    # committing the switch (d_espok=0, both busy bytes toggled) -- alongside
    # the oracle-identical witnesses every oracle agrees on.
    assert H(last, "edi") == 0x0BABE001, f"exit edi={last['edi']} != 0x0BABE001 (case A: null-DS read at base 0 = S1)"
    assert H(last, "esi") == 0x00010004, f"exit esi={last['esi']} != 0x00010004 (case B LDT-entry-0 JMP ok + case C err 0x0004 TI-preserved)"
    assert H(last, "ebp") == 0x000A0004, f"exit ebp={last['ebp']} != 0x000A0004 (QEMU: case-D #TS(0x0004) raised POST-commit -- oracle gap 1, pinned honestly)"
    assert H(last, "ebx") == 0x00008B89, f"exit ebx={last['ebx']} != 0x00008B89 (QEMU: the committed-then-faulted switch toggled both busy bytes -- oracle gap 1)"
    assert H(last, "ecx") == 0x0BABE001, f"exit ecx={last['ecx']} != 0x0BABE001 (case E: staged null DS reads S1 at base 0)"
    print(f"  exit witnesses (QEMU flow): edi=ecx=0x0BABE001 (null-DS base 0, cases A/E), esi=0x00010004 (LDT0 JMP + err 0x0004)")
    print(f"                            : ebp=0x000A0004 ebx=0x00008B89 (case-D #TS POST-commit -- oracle gap 1, pinned honestly)")
    print(f"                            : the RTL-side witnesses (ebp=0x010A0004, ebx=0x0000898B) are graded in step 7w")
elif test == "pxc04f":
    # R2-C03 S_FSTORE: crossing FSTP m64 at 0x2FFE, page 3 = phys 0x600000.
    assert H(last, "ecx") == 4,          f"exit ecx={last['ecx']} != 4 (two #PF + #GP + #UD delivered)"
    assert H(last, "edx") == 0x004000F4, f"exit edx={last['edx']} != 0x004000F4 (demand-page CR2 0x401000 with dx clobbered by the 0xF4 exit-port load)"
    assert H(last, "esi") == 0xCAFEBABE, f"exit esi={last['esi']} != 0xCAFEBABE (restarted pfault store)"
    assert H(last, "edi") == 0x600DF00D, f"exit edi={last['edi']} != 0x600DF00D (case A: page 1 untouched by the rejected crossing store)"
    assert H(last, "ebx") == 0x3FF00000, f"exit ebx={last['ebx']} != 0x3FF00000 (case B: high dword via phys 0x600002)"
    assert H(last, "ebp") == 0,          f"exit ebp={last['ebp']} != 0 (case B: low dword via phys 0x2FFE)"
    print(f"  exit witnesses            : ecx=4 edx=0x4000F4 (CR2 0x401000 | 0xF4 port) esi=0xCAFEBABE edi=0x600DF00D (atomicity) ebx=0x3FF00000 ebp=0 (split store)")
elif test == "pxc04e":
    # R2-C03 S_FENV_ST: crossing FNSTENV at 0x2FFE, page 3 = phys 0x600000.
    assert H(last, "ecx") == 4,          f"exit ecx={last['ecx']} != 4 (two #PF + #GP + #UD delivered)"
    assert H(last, "edx") == 0x004000F4, f"exit edx={last['edx']} != 0x004000F4 (demand-page CR2 0x401000 | 0xF4 port)"
    assert H(last, "esi") == 0xCAFEBABE, f"exit esi={last['esi']} != 0xCAFEBABE (restarted pfault store)"
    assert H(last, "edi") == 0x600DF00D, f"exit edi={last['edi']} != 0x600DF00D (case A: page 1 untouched by the rejected crossing store)"
    assert H(last, "ebx") == 0xFFFF037F, f"exit ebx={last['ebx']} != 0xFFFF037F (case B: (TW<<16)|CW through the split image)"
    assert H(last, "ebp") == 0,          f"exit ebp={last['ebp']} != 0 (case B: SW)"
    print(f"  exit witnesses            : ecx=4 edx=0x4000F4 esi=0xCAFEBABE edi=0x600DF00D (atomicity) ebx=0xFFFF037F ebp=0 (FENV CW/TW/SW)")
elif test == "pxc04":
    # R2-C03 S_LGDT: crossing 6-byte pseudo-descriptor read at 0x2FFE, page 3 = phys 0x600000.
    assert H(last, "ecx") == 4,          f"exit ecx={last['ecx']} != 4 (two #PF + #GP + #UD delivered)"
    assert H(last, "edx") == 0x004000F4, f"exit edx={last['edx']} != 0x004000F4 (demand-page CR2 0x401000 | 0xF4 port)"
    assert H(last, "esi") == 0xCAFEBABE, f"exit esi={last['esi']} != 0xCAFEBABE (restarted pfault store)"
    assert H(last, "edi") == 0x600DF00D, f"exit edi={last['edi']} != 0x600DF00D (case A: GDTR unchanged by the rejected crossing read)"
    assert H(last, "ebx") == 0x600DF00D, f"exit ebx={last['ebx']} != 0x600DF00D (case B: in-limit selector 0x28 committed through the new GDT)"
    assert H(last, "ebp") == 0xDEADBEEF, f"exit ebp={last['ebp']} != 0xDEADBEEF (case B: sentinel through the new GDT)"
    print(f"  exit witnesses            : ecx=4 edx=0x4000F4 esi=0xCAFEBABE edi=0x600DF00D (GDTR intact) ebx=0x600DF00D (limit) ebp=0xDEADBEEF (base in use)")
elif test == "pxc04i":
    # R2-C03 S_INT_PUSH: exception frame straddling 0x8E000, page 0x8E = phys 0x700000.
    assert H(last, "ecx") == 4,          f"exit ecx={last['ecx']} != 4 (#PF + #GP + two #UD delivered)"
    assert H(last, "edx") == 0x004000F4, f"exit edx={last['edx']} != 0x004000F4 (demand-page CR2 0x401000 | 0xF4 port)"
    assert H(last, "esi") == 0xCAFEBABE, f"exit esi={last['esi']} != 0xCAFEBABE (restarted pfault store)"
    assert H(last, "edi") == 0x600DF00D, f"exit edi={last['edi']} != 0x600DF00D (crossing frame EIP/CS verified from both pages)"
    assert H(last, "ebp") == 0x08,       f"exit ebp={last['ebp']} != 0x08 (saved CS recorded from the crossing frame)"
    print(f"  exit witnesses            : ecx=4 edx=0x4000F4 esi=0xCAFEBABE edi=0x600DF00D (frame ok) ebp=0x08 (saved CS)")
elif test == "pxc04t":
    # R2-C03 S_TSW_SAVE: outgoing TSS at 0x2FDE, saved EIP straddling onto phys 0x600000.
    assert H(last, "ecx") == 3,          f"exit ecx={last['ecx']} != 3 (pfault #PF + #GP + #UD delivered in the incoming task)"
    assert H(last, "edx") == 0x004000F4, f"exit edx={last['edx']} != 0x004000F4 (demand-page CR2 0x401000 | 0xF4 port)"
    assert H(last, "esi") == 0xCAFEBABE, f"exit esi={last['esi']} != 0xCAFEBABE (restarted pfault store)"
    assert H(last, "edi") == 0x600DF00D, f"exit edi={last['edi']} != 0x600DF00D (saved EIP/EAX/ESP/CS verified across the split)"
    assert H(last, "ebx") == 0x1A1A1A1A, f"exit ebx={last['ebx']} != 0x1A1A1A1A (saved EAX read back from phys 0x600006)"
    print(f"  exit witnesses            : ecx=3 edx=0x4000F4 esi=0xCAFEBABE edi=0x600DF00D (save ok) ebx=0x1A1A1A1A (saved EAX)")
elif test == "pxc04m":
    # R2-C03 S_INT_GATE: straddling IDT gate reads, page 5 = phys 0x601000.
    assert H(last, "ecx") == 5,          f"exit ecx={last['ecx']} != 5 (phase-1 #UD + phase-2 #PF + pfault #PF/#GP/#UD)"
    assert H(last, "edx") == 0x004000F4, f"exit edx={last['edx']} != 0x004000F4 (demand-page CR2 0x401000 | 0xF4 port)"
    assert H(last, "esi") == 0xCAFEBABE, f"exit esi={last['esi']} != 0xCAFEBABE (restarted pfault store)"
    assert H(last, "edi") == 0x600DF00D, f"exit edi={last['edi']} != 0x600DF00D (phase 1: straddling gate delivered correctly)"
    assert H(last, "ebx") == 0x600DF00D, f"exit ebx={last['ebx']} != 0x600DF00D (phase 2: delivery completed after the NP page was mapped)"
    print(f"  exit witnesses            : ecx=5 edx=0x4000F4 esi=0xCAFEBABE edi=0x600DF00D (phase 1) ebx=0x600DF00D (phase 2)")
elif test == "pxwrap":
    # Wrapped frame-probe matrix (differential half): the exit record must
    # carry the all-cases witness and the probe-fault count == the deny cases.
    assert H(last, "edi") == 0x11111111, f"exit edi={last['edi']} != 0x11111111 (all 351 cases ran)"
    assert H(last, "esi") == 351,        f"exit esi={last['esi']} != 351 (NCASES)"
    assert H(last, "ecx") == 348,        f"exit ecx={last['ecx']} != 348 (probe faults handled == deny cases)"
    print(f"  exit witnesses            : edi=0x11111111 esi=351 (cases) ecx=348 (denials handled)")
elif test == "pxwrapm":
    # Zero-bytes witness (QEMU side, pinned honestly): QEMU pushes the frame
    # slots incrementally, so each denial leaves k_fault slots written; the
    # terminal V86 case triple-faults and QEMU reboots (twice: m6 then m7).
    assert H(last, "edi") == 0x0D, f"exit edi={last['edi']} != 13 (QEMU's partial slots over m0..m5 -- oracle gap 1)"
    assert H(last, "esi") == 6,    f"exit esi={last['esi']} != 6 (m0..m5 completed)"
    assert H(last, "ecx") == 0x0E, f"exit ecx={last['ecx']} != 0xE (XOR of the written masks)"
    assert H(last, "ebp") == 0x5B, f"exit ebp={last['ebp']} != 91 (slots scanned)"
    assert H(last, "ebx") == 2,    f"exit ebx={last['ebx']} != 2 (m5's written count)"
    pm_seen = False
    rm_records = 0
    for r in recs:
        if (H(r, "cr0") & 1) == 1:
            pm_seen = True
        elif pm_seen and H(r, "cs") == 0xF000:
            rm_records += 1
    assert rm_records >= 30, f"only {rm_records} real-mode-after-PM records (the m6/m7 triple-fault reboots are missing)"
    print(f"  exit witnesses (QEMU flow): edi=13 (partial slots) esi=6 ecx=0xE ebp=91 ebx=2, {rm_records} post-PM real-mode records (the m6/m7 reboots -- oracle gap 2)")
    print(f"                            : the RTL-side witnesses (zero written slots, CR2 0x90FF8, old V86 context) are graded in step 7w")
elif test == "pxfrag":
    # Fragment-abort regression (differential half): the exit record must
    # carry the two-#PF + one-#GP count, the case-A CR2, the GDTR-unchanged
    # marker, the poisoned-limit (restart-at-frag1) proof, and the case-B/C
    # sentinel reads.
    assert H(last, "ecx") == 0x00000201, f"exit ecx={last['ecx']} != 0x201 (two #PF + one #GP)"
    assert H(last, "edx") == 0x300000F4, f"exit edx={last['edx']} != 0x300000F4 (case-A CR2 0x3000; low half is the exit port)"
    assert H(last, "edi") == 0x600DF00D, f"exit edi={last['edi']} != 0x600DF00D (case A: GDTR unchanged by the rejected read)"
    assert H(last, "ebx") == 0xFEEDFACE, f"exit ebx={last['ebx']} != 0xFEEDFACE (case A: restart installed the poisoned limit -- no stale frag1 merge)"
    assert H(last, "ebp") == 0xBEEFCAFE, f"exit ebp={last['ebp']} != 0xBEEFCAFE (case B: frag1-abort restart completed)"
    assert H(last, "esi") == 0xC001D00D, f"exit esi={last['esi']} != 0xC001D00D (case C control)"
    print(f"  exit witnesses            : ecx=0x201 (2x#PF+1x#GP) edx=0x300000F4 edi=0x600DF00D (unchanged)")
    print(f"                              ebx=0xFEEDFACE (re-read frag1) ebp=0xBEEFCAFE esi=0xC001D00D")
elif test == "pxdplan":
    # Frame page-plan probe (witness half, QEMU pinned honestly): QEMU pushes
    # incrementally, so C1 leaves two slots written and D=1 on the validated
    # early page; the RTL-side zero/D=0 witnesses are graded in step 7w.
    assert H(last, "edi") == 2,          f"exit edi={last['edi']} != 2 (QEMU's partial slots in C1 -- oracle gap 1)"
    assert H(last, "esi") == 2,          f"exit esi={last['esi']} != 2 (C1+C2 handled)"
    assert H(last, "ecx") == 0xD,        f"exit ecx={last['ecx']} != 0xD (D80=1 in C1, D90=0 in C2, both D=1 in C3)"
    assert H(last, "ebp") == 0x0009000E, f"exit ebp={last['ebp']} != 0x9000E (C1 CR2: first denied-page slot in push order)"
    assert H(last, "ebx") == 0x00080012, f"exit ebx={last['ebx']} != 0x80012 (C2 CR2: the first plan entry)"
    print(f"  exit witnesses (QEMU flow): edi=2 (partial slots) esi=2 ecx=0xD ebp=0x9000E ebx=0x80012")
    print(f"                            : the RTL-side witnesses (edi=0 zero bytes, ecx=0xC no D in validation)")
    print(f"                            : + the ordered FRMPG probe-beat sequence are graded in step 7w")
elif test == "pxwalkd":
    # REVIEW_Aug4 A4-C01: walk_set_dirty vs walk_is_write on the crossing-store probe.
    assert H(last, "esi") == 0x00800063, f"exit esi={last['esi']} != 0x00800063 (case 1 page-1 PTE: A|D set by the real write)"
    assert H(last, "edi") == 0x00801063, f"exit edi={last['edi']} != 0x00801063 (case 1 page-2 PTE: the clean-leaf probe COMPLETED -- pre-fix hang -- and the real write set D)"
    assert H(last, "ebp") == 0x00806063, f"exit ebp={last['ebp']} != 0x00806063 (case 3 page-1 PTE)"
    assert H(last, "ebx") == 0x00C000E3, f"exit ebx={last['ebx']} != 0x00C000E3 (case 3 4 MiB PDE: D set by the real write)"
    assert H(last, "edx") == 0x004000F4, f"exit edx={last['edx']} != 0x004000F4 (case 4 CR2 0x405000 = the page-2 probe address, dx clobbered by the 0xF4 port)"
    assert H(last, "ecx") == 0x01270303, f"exit ecx={last['ecx']} != 0x01270303 (case-2/case-4 err 0x03, case-2 page-2 D==0 + P==1, case-1 data, #PF count 2, case-4 page-2 P-only)"
    print(f"  exit witnesses            : esi=0x00800063 edi=0x00801063 (case 1: probe completed, D set)")
    print(f"                              ebp=0x00806063 ebx=0x00C000E3 (case 3: 4 MiB leaf, D set in the PDE)")
    print(f"                              edx=0x004000F4 (case 4: probe-fault CR2 = page-2 address | 0xF4 port)")
    print(f"                              ecx=0x01270303 (case 2: D==0/P==1 via test-only witnesses + both")
    print(f"                              probe/page-1 #PFs carry W/R=1; the A bit is a documented oracle gap)")
elif test == "ptswflt":
    # WITNESS gate: the GOLDEN pins QEMU's switch_tss_ra flow honestly. Every
    # injected case faults with the SAME vector + error code the RTL must
    # produce (the uniform semantics), but the partial state follows QEMU's
    # order: LDTR/segment faults are POST-commit (espok=0 in every half-word),
    # the incoming-read #PF happens BEFORE the outgoing save (esi bit 24 = 0),
    # and the busy bytes follow QEMU's order (JMP: outgoing clear before the
    # save; CALL: back-link before the incoming busy-set).
    assert H(last, "edi") == 0x00007003, f"exit edi={last['edi']} != 0x00007003 (P1: #PF err 0x003, CR2 page 0x7000 -- all oracles)"
    assert H(last, "esi") == 0x0000A01C, f"exit esi={last['esi']} != 0x0000A01C (QEMU: the P2 incoming-read #PF precedes the outgoing save -- the save-stands flag is 0)"
    assert H(last, "ebp") == 0x0A400A48, f"exit ebp={last['ebp']} != 0x0A400A48 (QEMU: P3 #TS(0x40) + P4 #TS(0x48) raised POST-commit, espok=0)"
    assert H(last, "ebx") == 0x0B500B58, f"exit ebx={last['ebx']} != 0x0B500B58 (P4b/P4c: presence-only incoming CS/SS -> #NP(0x50)/#NP(0x58) -- QEMU tss_load_seg ranks type before presence too)"
    assert H(last, "ecx") == 0x0B600A68, f"exit ecx={last['ecx']} != 0x0B600A68 (P4d #NP(0x60); P4e control: not-present DATA as CS -> #TS(0x68), type precedes presence)"
    assert H(last, "edx") == 0x14E300F4, f"exit edx={last['edx']} != 0x14E300F4 (QEMU busy order: JMP clears the outgoing BEFORE the save, the CALL back-link precedes the incoming busy-set; only p5b_run/p5c_run stay busy)"
    assert H(last, "eax") == 0x001E0042, f"exit eax={last['eax']} != 0x001E0042 (P5c: the CALL back-link store faults at incoming TSS offset 0, CR2 0x1E000 -- all oracles)"
    print(f"  exit witnesses (QEMU flow): edi=0x00007003 esi=0x0000A01C ebp=0x0A400A48 ebx=0x0B500B58")
    print(f"                            : ecx=0x0B600A68 edx=0x14E300F4 eax=0x001E0042 (post-commit validation,")
    print(f"                            : no outgoing save on P2, QEMU busy order -- the phase deltas are pinned)")
    print(f"                            : the RTL-side phase-model witnesses are graded in step 7w")
print("  VALID: the golden captures every witness the finding is graded on")
PYEOF
fi

# --- 6. comparator sys-diff path: golden self-diff sanity ----------------------
# Confirms the comparator's sys-field path round-trips: the golden must self-diff
# EQUIVALENT under compare.py --mode func with BOTH sides sys:true, so the cr0 +
# selectors + GPRs + eflags + eip gated compare (and the segment-hidden
# intersection) is exercised end-to-end. The REAL RTL differential (RTL trace vs
# golden) follows in step 7 for the tests the M2S.1 RTL supports (pseg).
say "6. comparator sys-diff path: golden self-diff must be EQUIVALENT"
COMPARE="$REPO/verif/diff/compare.py"
set +e
DIFF_OUT="$("$PY" "$COMPARE" --mode func "$OUT" "$OUT" 2>/dev/null)"
DIFF_RC=$?
set -e
echo "$DIFF_OUT" | sed 's/^/  /'
[[ "$DIFF_RC" == "0" ]] || { echo "FATAL: golden self-diff did not exit 0 (sys path broken)"; exit 1; }
echo "$DIFF_OUT" | grep -q "sys compared: True" \
    || { echo "FATAL: comparator did not engage the sys-field compare (sys compared != True)"; exit 1; }
echo "  SELF-DIFF-OK: comparator sys path engaged (sys compared: True) + EQUIVALENT"

# --- 7. RTL (Producer C) sys-diff vs the golden --------------------------------
# For tests the RTL system-mode core supports, build the Verilator TB, run it in
# --system mode on the SAME bare-metal image, and assert compare.py --mode func
# (sys) is EQUIVALENT to the golden across cr0..cr4 + the 6 selectors + GPRs +
# eflags + eip.
#
#   M2S.1 (DONE): pseg = real mode + real->protected + protected-mode
#                 SEGMENTATION (NO paging) -> REAL RTL sys-diff vs the golden.
#   M2S.2 (DONE — Phase 2 FLIP POINT): the paging tests (pmode = identity 4 MiB
#                 PSE; ppage = focused NON-IDENTITY 4 KiB) enable CR0.PG/CR3
#                 [+CR4.PSE for pmode]. The RTL now implements the 2-level paging
#                 MMU (CR3->PDE->PTE walk, split I/D TLBs, 4 KiB + 4 MiB pages,
#                 A/D writeback, P/RW/US decision; #PF DECISION computed, delivery
#                 = M2S.3), so "pmode" and "ppage" are in RTL_SYS_TESTS below and
#                 their RTL --system traces are DIFFED against the golden (no
#                 longer self-diff-only): EQUIVALENT across the paging-enable +
#                 paged execution (cr0..cr4 + selectors + GPRs + eflags + eip).
#   M2S.3 (DONE — Phase 2 FLIP POINT): the IDT-delivery tests "pintr" (software
#                 INT n / INT3 / INTO -> interrupt/trap gate handlers -> IRET) and
#                 "pfault" (#PF / #GP / #UD hardware faults now DELIVERING through
#                 the IDT -> handler -> IRET / fault restart). The RTL implements
#                 IDT delivery (gate read -> CS-descriptor load -> exception-frame
#                 push of EFLAGS/CS/EIP[+error code] -> CS:EIP <- gate, IF/TF
#                 gating) + IRET (pop EIP/CS/EFLAGS + CS reload), so both are in
#                 RTL_SYS_TESTS and their RTL --system traces are DIFFED against the
#                 golden (no longer self-diff-only): EQUIVALENT across the
#                 fault/INT -> frame-push -> handler -> IRET sequence (cr0..cr4 +
#                 cr2 + selectors + GPRs + eflags + eip). Same-privilege (CPL0)
#                 delivery; cross-privilege stack switch via the TSS is M2S.4.
#   M2S.4 (DONE — Phase 2 FLIP POINT): "pcpl" exercises the privilege machinery —
#                 TR/TSS (LTR/STR + SS0:ESP0), the transfer DOWN to CPL3, CROSS-
#                 PRIVILEGE interrupt delivery (target CS.DPL < CPL -> load SS:ESP
#                 from TSS.ssN:espN + push the LARGER 5-word frame + CPL 3->0), the
#                 INTER-PRIVILEGE IRET (pop EIP/CS/EFLAGS + ESP/SS, CPL 0->3), and
#                 the gate/CS protection checks (gate Present/DPL, target CS
#                 present/type/DPL) deferred from M2S.3. The RTL implements all of
#                 these, so "pcpl" is in RTL_SYS_TESTS and its RTL --system trace is
#                 DIFFED against the golden (no longer self-diff-only): EQUIVALENT
#                 across the CPL transition + handler + inter-priv IRET (cr0..cr4 +
#                 selectors + GPRs + eflags + eip).
#   M2S.4b (DONE — RTL diff lands here): "ptask" exercises the HARDWARE TASK SWITCH
#                 (far JMP to a 32-bit TSS): SAVE the outgoing task state into the
#                 current TSS (EIP/EFLAGS/GPRs/segs at the documented offsets), LOAD
#                 the incoming state from the new TSS (CR3/EIP/EFLAGS/GPRs/segments),
#                 reload the segment descriptors, set CR0.TS, toggle the descriptor
#                 busy bits (JMP clears the outgoing B->9, sets the incoming 9->B),
#                 and point TR at the new TSS. The core.sv S_TSW_SAVE/_READ/_SEG/
#                 _BUSY micro-sequence (gated sys_mode) implements all of this, so
#                 "ptask" is now in RTL_SYS_TESTS and its RTL --system trace is DIFFED
#                 against the golden (no longer self-diff-only): EQUIVALENT across the
#                 task switch + state save/reload + busy-bit toggle (292 records). A
#                 JMP does NOT set NT/back-link; the CALL/INT-task-gate (NT+back-link)
#                 and the round-trip switch-back remain documented deferrals.
#   M7.2 (DONE — RTL diff lands here): "pv86" exercises VIRTUAL-8086
#                 mode — V86 entry (EFLAGS.VM 0->1 + CPL 0->3 + sel<<4 seg bases) by
#                 IRET, V86 segmentation, the IOPL guard (IOPL<3 -> CLI/STI/PUSHF/
#                 POPF/INT n #GP to the CPL0 monitor = method-1 / VME-OFF), the
#                 V86 interrupt/fault DELIVERY (the 9-word V86 frame on TSS.SS0:ESP0,
#                 VM cleared, DS/ES/FS/GS zeroed), and the IRET back into V86. The
#                 V86 RTL delta (core.sv: v86=sys_mode&&eflags[17], iopl guards, the
#                 sel<<4 MOV-sreg/far-jump path, the S_INT_PUSH 9-word from_v86 frame +
#                 the S_IRET return-into-V86) is gated behind `v86` so it is INERT when
#                 EFLAGS.VM=0 (every prior sys gate stays byte-identical). pv86 is now
#                 in RTL_SYS_TESTS for the real RTL --system V86 diff vs the golden.
#   REVIEW_Aug3 C-02/C-04 (REGRESSION tests): "ptaskpg" (C-02: paged task
#                 switch, every object non-identity-mapped, straddling GDT +
#                 TSS2, outgoing/incoming LDTs differing in base+limit, TI=1
#                 incoming CS/SS/DS), "pretfoutpg" (C-02 + H-02: paged outer
#                 RETF, 32-bit AND 16-bit operand sizes, outer ESP/SS pops on
#                 a different physical page than the linear page), "pcalltss"
#                 (C-04: far CALL to an available TSS = NESTING switch --
#                 back-link, NT, both descriptors busy, NT-IRET return),
#                 "pjmpgate" (C-04: far JMP through a call gate to a more-
#                 privileged NONCONFORMING target #GPs, the far CALL succeeds,
#                 the conforming-target JMP keeps CPL). Each has a QEMU golden
#                 differential + a HEAD-build NEGATIVE CONTROL recorded in its
#                 manifest.json, and a step-5f witness validation above.
#   REVIEW_Aug3 H-11b/H-02/M-01 (REGRESSION tests): "pltr" (H-11b: LTR busy-
#                 byte write before TR commits + re-LTR #GP + null LLDT under
#                 paging with GDT[0] non-present; GATE CURRENTLY RED -- the
#                 fix's null-LLDT suppression does not reach the S_LTR FSM
#                 under paging because S_LTR is `translatable` and the S_WALK
#                 divert is not mem_req-gated; see tests/pltr/manifest.json
#                 rtl_blocker), "pretfres" (H-02: same-priv RETF to a not-
#                 present CS faults with ESP UNCHANGED, 32- and 16-bit, + the
#                 16-bit outer RETF's zero-extended outer SP), "piopermwrap"
#                 (M-01: word/dword I/O wrapping past port 0xFFFF denied
#                 #GP(0); differential because QEMU denies too via the 0xFF
#                 bitmap terminator byte). "piretgp0" (H-03 + the H-02
#                 offset-past-limit case) is NOT in RTL_SYS_TESTS -- QEMU
#                 8.2.2 has no return-EIP-vs-limit check (and the H-03(b)
#                 DPL<RPL anomaly is unreachable through legal loads), so it
#                 is a WITNESS gate: WITNESS_TESTS above, graded in step 7w.
#   REVIEW1_Aug3 R2-C01 (REGRESSION test): "pxfer" (S_LJMP per-kind
#                 privilege/type validation + the system-descriptor dispatch
#                 precedence: twenty REJECTED far transfers --
#                 direct CALL RPL>CPL, direct JMP conforming DPL>CPL, RETF to
#                 a system descriptor, JMP to an LDT-resident TSS, JMP to a
#                 not-present TSS (#NP), CALL through a not-present call gate
#                 (#NP), call-gate target nonconforming DPL>CPL, from
#                 CPL3: direct JMP nonconforming DPL<CPL, CALL to a TSS
#                 DPL<CPL, RETF popped RPL<CPL, and the combined-invalid
#                 matrix (TYPE/DPL classification BEFORE PRESENCE): busy TSS
#                 P=0 (#GP, not #NP; present-busy control), LDT descriptor
#                 P=0 (#GP, not #NP; present-LDT control), task gate P=0
#                 (#NP) vs RPL>DPL (#GP), TSS P=0 with DPL<CPL (#GP; DPL3
#                 control #NP), present task gate DPL<CPL (#GP), call gate
#                 P=0 with DPL<CPL (#GP; CPL0 presence-only control = case 6)
#                 -- each witnessed to perform
#                 NO stack write and NO busy-bit/descriptor write -- plus three ACCEPTED
#                 controls: conforming JMP, same-level CALL/RETF, and a JMP
#                 to a valid available TSS). Differential: QEMU implements
#                 every rule; the one oracle gap (QEMU #TS vs SDM #GP for the
#                 LDT-resident TSS) is bridged by the pssiret shared-handler
#                 pattern, the vector graded from +ven_faultlog in step 7d.
#   REVIEW1_Aug3 R2-C02 (REGRESSION test): "pselnull" (selector nullness,
#                 LDT entry 0, error-code TI) is NOT in RTL_SYS_TESTS -- case
#                 D (incoming task LDTR 0x0004 -> #TS) cannot be diffed:
#                 QEMU raises the same #TS only AFTER committing the switch
#                 (oracle gap 1), so it is a WITNESS gate: WITNESS_TESTS
#                 above, graded in step 7w. Its other four cases (null DS
#                 load with GDT[0] poison+non-present, LDT-entry-0 far JMP,
#                 OOB LDT selector error code, paged switch with a null
#                 incoming DS) ARE QEMU-identical and are pinned by the
#                 golden + the 7w final-GPR witnesses.
RTL_SYS_TESTS="pseg pmode psysfpreloc ppage pxpage psldram pintr pintr16 pfault pde pcpl pssiret pstk16 pdf ptask ptaskcpl ptaskv86 pfcpl3 pdebug pv86 ppopf pfarok pcalltss ptaskpg pjmpgate pretfoutpg pltr pretfres piopermwrap pxfer pxprobe pcgparam pcg16 pcgpg pxc04 pxc04i pxc04f pxc04e pxc04t pxc04m pxwalkd pjmpoff pdescprec pint16f psamepf pxwrap pxfrag psoccallfmem"
if echo " $RTL_SYS_TESTS " | grep -q " $TEST "; then
  say "7. RTL (Producer C) --system sys-diff vs golden (segmentation/paging gate)"
  TB="${TB_BIN:-$REPO/verif/tb/obj_dir/tb_ventium}"
  [[ -n "${TB_BIN:-}" ]] || make -C "$REPO/verif/tb" rtl >/dev/null 2>&1
  [[ -x "$TB" ]] || { echo "FATAL: RTL TB $TB not built"; exit 1; }
  RTL_OUT="$OUTDIR/$TEST.rtl.sys.vtrace"
  # --max-insn matches the golden length cap; --quiesce generous so the boot's
  # icache fills + descriptor reads do not trip a premature idle stop.
  "$TB" --image "$IMG" --system --out "$RTL_OUT" \
      --max-insn "$MAXI" --quiesce 400 >/dev/null 2>&1 || true
  echo "  RTL sys trace: $RTL_OUT ($(wc -l < "$RTL_OUT") lines)"
  set +e
  RDIFF_OUT="$("$PY" "$COMPARE" --mode func --all --max-report 8 "$OUT" "$RTL_OUT" 2>/dev/null)"
  RDIFF_RC=$?
  set -e
  echo "$RDIFF_OUT" | sed 's/^/  /'
  [[ "$RDIFF_RC" == "0" ]] || { echo "FATAL: RTL sys-diff DIVERGENT vs golden"; exit 1; }
  echo "  RTL-SYS-DIFF-OK: RTL system-mode trace EQUIVALENT to the golden"
  echo "                   (cr0..cr4 + selectors + GPRs + eflags + eip)"

  # --- 7b. pssiret only: grade the FAULT VECTORS, which the trace diff cannot ----
  # pssiret routes IDT vectors 11 (#NP) and 12 (#SS) to ONE handler on purpose, so
  # that QEMU's non-SDM choice of #NP for a not-present stack segment (seg_helper.c
  # helper_ret_protected -> EXCP0B_NOSEG; SDM Vol.2A IRET and Vol.3A 6.15 both say
  # #SS) cannot make the two oracles diverge. That shared entry is exactly what
  # makes the vector NUMBER invisible to the differential diff -- so grade it here,
  # directly, from the RTL fault log. Without this the SDM behaviour would be
  # unverified and the sharing would read as if it were hiding a difference.
  if [[ "$TEST" == "pssiret" ]]; then
    FLOG="$OUTDIR/$TEST.faultlog"
    "$TB" --image "$IMG" --system --out /dev/null --max-insn "$MAXI" \
        --quiesce 400 +ven_faultlog >"$FLOG" 2>&1 || true
    # Expected, in order: #GP(0x30) case A, #GP(0x38) case B, #SS(0x40) case C.
    GP30="$(grep -c '^\[FAULT\] vec=13 .*err=00000030' "$FLOG" || true)"
    GP38="$(grep -c '^\[FAULT\] vec=13 .*err=00000038' "$FLOG" || true)"
    SS40="$(grep -c '^\[FAULT\] vec=12 .*err=00000040' "$FLOG" || true)"
    NP40="$(grep -c '^\[FAULT\] vec=11 .*err=00000040' "$FLOG" || true)"
    echo "  fault log: #GP(0x30)=$GP30  #GP(0x38)=$GP38  #SS(0x40)=$SS40  #NP(0x40)=$NP40"
    if [[ "$GP30" -lt 1 || "$GP38" -lt 1 ]]; then
      echo "FATAL: pssiret: the read-only / wrong-DPL stack selectors did not raise #GP"
      echo "       with the expected error codes (see $FLOG)"; exit 1
    fi
    if [[ "$SS40" -lt 1 ]]; then
      echo "FATAL: pssiret: a NOT-PRESENT stack segment on an outer-level IRET must"
      echo "       raise #SS(12) per SDM Vol.2A IRET / Vol.3A 6.15. Got #NP(11)=$NP40."
      echo "       (QEMU raises #NP here; Ventium must not copy that.) See $FLOG"; exit 1
    fi
    echo "  RTL-FAULT-VECTOR-OK: #GP(0x30), #GP(0x38) and #SS(0x40) all raised;"
    echo "                       #SS follows the SDM, not QEMU's #NP"

    # --- 7c. REVIEW_aug2 H-05: a FAULTING IRET must not re-arm NMI --------------
    # Nothing in the corpus drives the core's nmi input, so this property is
    # unreachable without stimulus: +ven_nmi_arm forces nmi_in_progress out of reset
    # ("pretend an NMI handler is running"), and the core counts faults delivered
    # from an IRET state while NMI is still armed. pssiret rejects FOUR frames (three inter-privilege, one same-privilege), so
    # the count must be 3. If the re-arm moves back to IRET DECODE the first IRET
    # disarms NMI before it ever reaches its stack reads and the count is 0 -- the
    # FINAL register state is identical either way, which is why the count is what
    # gets measured. Verified both ways by reintroducing the defect.
    H05="$("$TB" --image "$IMG" --system --out /dev/null --max-insn "$MAXI" \
            --quiesce 400 +ven_nmi_arm 2>&1 | sed -n 's/.*\[H05\][^:]*: //p')"
    echo "  H-05: faults delivered from an IRET with NMI still armed: ${H05:-<none>}"
    if [[ "${H05:-0}" != "5" ]]; then
      echo "FATAL: pssiret H-05: expected 5 armed-NMI IRET faults, got '${H05:-<none>}'."
      echo "       0 means the NMI re-arm happened at IRET DECODE again, so an IRET"
      echo "       that FAULTS re-enables NMI while the original frame is still live."
      exit 1
    fi
    echo "  RTL-H05-OK: a faulting IRET leaves NMI blocked; the re-arm is at commit"
  fi

  # --- 7d. pxfer only: grade the case-4 fault VECTOR, which the trace diff cannot ----
  # pxfer routes IDT vectors 10 (#TS) and 13 (#GP) to ONE handler entry on
  # purpose -- the pssiret precedent -- so that QEMU's deviant #TS(0x0004) for
  # a direct JMP to an LDT-resident TSS (switch_tss_ra's `tss_selector & 4`
  # check fires #TS for jumps and IRETs alike) and the RTL's SDM-mandated
  # #GP(0x0004) (Vol.3A 8.2.2: TI-set TSS access is #GP during CALLs/JMPs,
  # #TS only during IRETs) produce identical flows for the step-7 diff. That
  # shared entry makes the vector NUMBER invisible to the differential -- so
  # grade it here, directly, from the RTL fault log: exactly one
  # vec=13 err=00000004 (TI PRESERVED -- the R2-C02 selector_error form, not
  # {sel[15:3],3'b000}=0x0000) and no vec=10 at all. Without this the SDM
  # behaviour would be unverified and the sharing would read as if it were
  # hiding a difference.
  if [[ "$TEST" == "pxfer" ]]; then
    FLOG="$OUTDIR/$TEST.faultlog"
    "$TB" --image "$IMG" --system --out /dev/null --max-insn "$MAXI" \
        --quiesce 400 +ven_faultlog >"$FLOG" 2>&1 || true
    GP04="$(grep -c '^\[FAULT\] vec=13 .*err=00000004' "$FLOG" || true)"
    TSANY="$(grep -c '^\[FAULT\] vec=10 ' "$FLOG" || true)"
    echo "  fault log: #GP(0x0004)=$GP04 (want 1: the LDT-resident TSS, SDM vector + TI preserved)  #TS(any)=$TSANY (want 0)"
    if [[ "$GP04" != "1" ]]; then
      echo "FATAL: pxfer: the JMP to the LDT-resident TSS (selector 0x0004) must raise"
      echo "       #GP(0x0004) per SDM Vol.3A 8.2.2 -- vector 13, error code with TI"
      echo "       preserved. Got #GP(0x0004)=$GP04. (QEMU raises #TS here; Ventium"
      echo "       must not copy that. HEAD accepted the transfer and faults nothing."
      echo "       The old {sel[15:3],3'b000} error form would give err=00000000.)"
      echo "       See $FLOG"; exit 1
    fi
    if [[ "$TSANY" != "0" ]]; then
      echo "FATAL: pxfer: a #TS fired -- the LDT-resident TSS must be #GP (direct JMP),"
      echo "       not #TS (that is the QEMU deviation and the IRET-return form). See $FLOG"
      exit 1
    fi
    echo "  RTL-FAULT-VECTOR-OK: #GP(0x0004) raised for the LDT-resident TSS;"
    echo "                       the vector follows the SDM, not QEMU's #TS"
  fi

  # --- 7e. pxprobe only: the pre-commit frame fault must not escalate ----------
  # The step-7 differential already proves the #PF ordering, the old-context
  # visibility and (via CR2/the handler's edi) the supervisor classification +
  # first-push CR2. What the trace cannot show is that EXACTLY ONE fault fired
  # -- a delivery that faults AFTER a partial commit cascades (#PF->#GP->#DF)
  # through handlers this image deliberately routes to observable slots, and a
  # double fault would shutdown without the exit. Grade the fault log: exactly
  # one vec=14 with err=00000002 (W=1,P=0,US=0 -- the frame push is a
  # supervisor access even before the CPL commit), and no #DF/#GP at all.
  if [[ "$TEST" == "pxprobe" ]]; then
    FLOG="$OUTDIR/$TEST.faultlog"
    "$TB" --image "$IMG" --system --out /dev/null --max-insn "$MAXI" \
        --quiesce 400 +ven_faultlog >"$FLOG" 2>&1 || true
    PF2="$(grep -c '^\[FAULT\] vec=14 .*err=00000002' "$FLOG" || true)"
    PFANY="$(grep -c '^\[FAULT\] vec=14 ' "$FLOG" || true)"
    DF="$(grep -c '^\[FAULT\] vec=8 ' "$FLOG" || true)"
    GP="$(grep -c '^\[FAULT\] vec=13 ' "$FLOG" || true)"
    echo "  fault log: #PF(err=2)=$PF2 (want 1)  #PF(any)=$PFANY  #DF=$DF (want 0)  #GP=$GP (want 0)"
    if [[ "$PF2" != "1" || "$PFANY" != "1" || "$DF" != "0" || "$GP" != "0" ]]; then
      echo "FATAL: pxprobe: the straddling frame probe must raise EXACTLY ONE #PF with"
      echo "       err=00000002 (supervisor class, write, not-present) and never"
      echo "       escalate. A user-class err=6 means the probe regressed to the"
      echo "       interrupted task's CPL; a #DF/#GP means a partial commit. See $FLOG"
      exit 1
    fi
    echo "  RTL-PROBE-OK: one supervisor-class #PF, no escalation cascade"
  fi

  # --- 7x. pxwrap only: the wrapped-probe matrix must fault EXACTLY as enumerated --
  # The step-7 differential already grades every denial's CR2 (cr2 is compared
  # on every record). What the trace cannot show is the COUNT: exactly one
  # supervisor-class #PF (err=2) per deny case, the #GP(0x60) trigger
  # deliveries, and NO #DF anywhere (a probe that faults after a partial
  # commit would cascade: the #PF would land in the committed CPL0 context
  # and the DPL=3 handler target would escalate #GP -> #DF -> shutdown).
  if [[ "$TEST" == "pxwrap" ]]; then
    FLOG="$OUTDIR/$TEST.faultlog"
    "$TB" --image "$IMG" --system --out /dev/null --max-insn "$MAXI" \
        --quiesce 400 +ven_faultlog >"$FLOG" 2>&1 || true
    EPF2="$(grep -oP '"exp_pf2":\s*\K[0-9]+' "$TDIR/manifest.json")"
    EGP60="$(grep -oP '"exp_gp60":\s*\K[0-9]+' "$TDIR/manifest.json")"
    # Count only the canonical +ven_faultlog records.  VEN_DBG_CORE emits a
    # second `tb: FLT` observer for each delivery, so field-only substring
    # counts double every event in the deployed debug profile.
    # The TB's own stdout can interleave INTO a [FAULT] line (observed), so
    # count the err= field, which survives the splice: err=00000002 is the
    # only legal #PF class here, 00000060/00000000 the only legal #GPs.
    PF2="$(grep -c 'err=00000002' "$FLOG" || true)"
    GP60="$(grep -c 'err=00000060' "$FLOG" || true)"
    DF="$(grep -c 'vec=8 ' "$FLOG" || true)"
    PFBAD="$(grep -E 'err=' "$FLOG" | grep -cvE 'err=00000002|err=00000060|err=00000000' || true)"
    echo "  fault log: #PF(err=2)=$PF2 (want $EPF2)  #GP(0x60)=$GP60 (want $EGP60)  #DF=$DF (want 0)  other-class=$PFBAD (want 0)"
    if [[ "$PF2" != "$EPF2" || "$GP60" != "$EGP60" || "$PFBAD" != "0" || "$DF" != "0" ]]; then
      echo "FATAL: pxwrap: the page denials must raise EXACTLY $EPF2 supervisor-class"
      echo "       #PFs (err=00000002), each #GP-trigger case must deliver its two #GP(0x60),"
      echo "       and nothing may escalate. A missing #PF means a denial went unseen"
      echo "       (a wrapped page the probe did not enumerate); a #DF means a partial"
      echo "       commit. See $FLOG"
      exit 1
    fi
    echo "  RTL-WRAP-OK: $EPF2 supervisor-class probe faults, $EGP60 trigger deliveries, no escalation"
  fi

  # --- 7f. pcgpg only: the two pre-commit faults must not escalate ------------
  # R2-H05's paged call-gate suite raises TWO #PFs by design: phase C (the
  # frame's destination page not present -> write probe faults, supervisor
  # class err=2) and phase D (the param SOURCE page not present -> the
  # S_CG_PRD read faults, read class err=0), both in the OLD context. The
  # differential proves the flows; the fault log proves NOTHING ELSE faulted
  # (a partial commit would cascade into #GP/#DF).
  if [[ "$TEST" == "pcgpg" ]]; then
    FLOG="$OUTDIR/$TEST.faultlog"
    "$TB" --image "$IMG" --system --out /dev/null --max-insn "$MAXI" \
        --quiesce 400 +ven_faultlog >"$FLOG" 2>&1 || true
    PFW="$(grep -c '^\[FAULT\] vec=14 .*err=00000002' "$FLOG" || true)"
    PFR="$(grep -c '^\[FAULT\] vec=14 .*err=00000000' "$FLOG" || true)"
    PFANY="$(grep -c '^\[FAULT\] vec=14 ' "$FLOG" || true)"
    DF="$(grep -c '^\[FAULT\] vec=8 ' "$FLOG" || true)"
    GP="$(grep -c '^\[FAULT\] vec=13 ' "$FLOG" || true)"
    echo "  fault log: #PF(err=2)=$PFW (want 1)  #PF(err=0)=$PFR (want 1)  #PF(any)=$PFANY  #DF=$DF (want 0)  #GP=$GP (want 0)"
    if [[ "$PFW" != "1" || "$PFR" != "1" || "$PFANY" != "2" || "$DF" != "0" || "$GP" != "0" ]]; then
      echo "FATAL: pcgpg: expected exactly the destination-page write-probe #PF(2)"
      echo "       and the source-page read #PF(0), with no escalation. See $FLOG"
      exit 1
    fi
    echo "  RTL-CGPF-OK: destination write-probe + source read faults, no cascade"
  fi
else
  say "7. RTL --system sys-diff: SKIPPED for '$TEST'"
  if echo " $WITNESS_TESTS " | grep -q " $TEST "; then
    echo "  ($TEST is a WITNESS gate: QEMU 8.2.2 cannot be the differential"
    echo "   oracle for every graded behaviour (see the manifest's oracle_gaps),"
    echo "   so a trace diff cannot encode it. The RTL side is graded by"
    echo "   witnesses in step 7w below; the golden above pins QEMU's deviant"
    echo "   flow and step 5f asserted it.)"
  elif [[ "$TEST" == "ppriv" ]]; then
    echo "  (REVIEW_aug2 H-06. The GOLDEN is fully validated above and pins the"
    echo "   behaviour: qemu 8.2.2 raises #GP(0) at CPL3 for WBINVD, INVD and (with"
    echo "   CR4.TSD=1) RDTSC. The RTL side cannot run yet, and the reason is a"
    echo "   SEPARATE defect, not a property of H-06:"
    echo "     * the decoder only recognises RDTSC/INVD/WBINVD when cosim_en or"
    echo "       soc_en is set; with both off they are out-of-scope opcodes that HALT"
    echo "       before the privilege predicate is ever consulted, and"
    echo "     * tb_main.cpp's --soc-en flag is a NO-OP in this build: the"
    echo "       'top->soc_en = args.soc_en' assignment sits inside #ifdef"
    echo "       VEN_KV260_SOC, and ventium_top ties the core's soc_en to 1'b0 in the"
    echo "       non-KV260 generate branch. Passing --soc-en changes nothing."
    echo "   So the RTL fix (d_cacheinv + rdtsc_priv in core.sv) is LIVE only in the"
    echo "   soc_en=1 configurations -- which is where it matters, since that is the"
    echo "   deployed config -- and is UNGATED here. Enabling this needs --soc-en to"
    echo "   reach the core in the default TB build; tracked separately."
  elif echo " $INTR_TESTS " | grep -q " $TEST "; then
    echo "  ($TEST exercises M2S.3 IDT DELIVERY (interrupts/faults); the RTL"
    echo "   delivery path lands in M2S.3 Phase 2, so this is golden self-diff +"
    echo "   the step-5b delivery validation only. Phase 2 adds $TEST to"
    echo "   RTL_SYS_TESTS for a real RTL --system diff across the"
    echo "   fault->frame-push->handler->IRET sequence.)"
  elif echo " $XPRIV_TESTS " | grep -q " $TEST "; then
    echo "  ($TEST exercises M2S.4 CROSS-PRIVILEGE delivery (TSS stack switch +"
    echo "   the 5-word frame + inter-priv IRET); the RTL cross-priv path lands in"
    echo "   M2S.4 Phase 2, so this is golden self-diff + the step-5c cross-priv"
    echo "   validation only. Phase 2 adds $TEST to RTL_SYS_TESTS for a real RTL"
    echo "   --system diff across the CPL transition + handler + inter-priv IRET.)"
  elif echo " $TASK_TESTS " | grep -q " $TEST "; then
    echo "  ($TEST exercises the M2S.4 STRETCH HARDWARE TASK SWITCH (far JMP to a"
    echo "   TSS: outgoing state save + incoming state load + busy-bit toggle); the"
    echo "   RTL task-switch path lands in M2S.4 Phase 2, so this is golden"
    echo "   self-diff + the step-5d task-switch validation only. Phase 2 adds"
    echo "   $TEST to RTL_SYS_TESTS for a real RTL --system diff across the switch.)"
  elif echo " $V86_TESTS " | grep -q " $TEST "; then
    echo "  ($TEST exercises M7.2 VIRTUAL-8086 MODE (V86 entry EFLAGS.VM 0->1 +"
    echo "   CPL 0->3 + sel<<4 bases; the IOPL guard CLI/STI/PUSHF/POPF/INT n #GP to"
    echo "   the CPL0 monitor = method-1 / VME-OFF; the 9-word V86 frame on"
    echo "   TSS.SS0:ESP0 with VM cleared; the IRET back into V86). The V86 RTL delta"
    echo "   is de-risk-specified + gated behind a new 'v86' so it is INERT when"
    echo "   EFLAGS.VM=0 (every prior sys gate stays byte-identical), and lands in"
    echo "   IMPLEMENT — so this is golden self-diff + the step-5e V86 validation"
    echo "   only. Implement adds $TEST to RTL_SYS_TESTS for the real RTL --system"
    echo "   V86 diff across V86 entry -> IOPL #GP -> 9-word frame -> monitor -> IRET.)"
  else
    echo "  ($TEST exercises paging = M2S.2 RTL; not yet in the RTL, so golden"
    echo "   self-diff only. Phase 2 adds it to RTL_SYS_TESTS for a real RTL diff.)"
  fi
fi

# --- 7w. WITNESS_TESTS: grade the RTL run by witnesses, not by a trace diff --
# piretgp0 (REVIEW_Aug3 H-03 + the H-02 offset-past-limit case): the RTL must
# raise #GP(0) -- error code ZERO, not the selector -- at BOTH the over-limit
# IRET (A2) and the over-limit RETF (A3), with ESP unchanged, while the
# at-limit IRET (A1) succeeds and the case-B segment-cleanup boundary matches
# every oracle. QEMU cannot be the oracle for A2/A3 (it transfers and runs
# past the limit; oracle gap 1 in the manifest), so these are read off the
# RTL trace's final record + +ven_faultlog, like the standalone ioperm gate.
# pselnull (REVIEW1_Aug3 R2-C02): cases A/B/C/E are QEMU-identical, but case D
# (incoming task LDTR 0x0004 -> #TS) cannot be diffed -- QEMU raises the same
# #TS(0x0004) only AFTER committing the switch (CR0.TS, busy bits, new task
# context; oracle gap 1 in the manifest) while the fix's C-06 prevalidation
# raises it BEFORE any state moves. Graded here: the final record must carry
# the null-base proofs (edi=ecx=0x0BABE001 = the S1 sentinel read through the
# null DS at base 0, never the poison base), the LDT-entry-0 + TI-error-code
# proof (esi=0x00010004), the outgoing-context #TS (ebp=0x010A0004: ESP at
# the fault == the pre-switch ESP) and the NO-busy-write proof
# (ebx=0x0000898B), plus +ven_faultlog for the two fault deliveries.
if echo " $WITNESS_TESTS " | grep -q " $TEST "; then
  say "7w. RTL WITNESS grading (no differential: QEMU lacks the graded check)"
  TB="${TB_BIN:-$REPO/verif/tb/obj_dir/tb_ventium}"
  [[ -n "${TB_BIN:-}" ]] || make -C "$REPO/verif/tb" rtl >/dev/null 2>&1
  [[ -x "$TB" ]] || { echo "FATAL: RTL TB $TB not built"; exit 1; }
  WTR="$OUTDIR/$TEST.rtl.wit.vtrace"
  FLOG="$OUTDIR/$TEST.faultlog"
  "$TB" --image "$IMG" --system --out "$WTR" --max-insn "$MAXI" \
      --quiesce 400 +ven_faultlog >"$FLOG" 2>&1 || true
  echo "  RTL witness trace: $WTR ($(wc -l < "$WTR") lines)"
  if [[ "$TEST" == "piretgp0" ]]; then
  PYTHONPATH="$REPO/verif/diff" "$PY" - "$WTR" <<'PYEOF'
import sys
import tracefmt as t
tr = t.read_trace(sys.argv[1])
last = tr.records[-1]
def H(k): return int(last[k], 16)
assert H("edi") == 0xA1A1A1A1, f"edi={last['edi']} != 0xA1A1A1A1 (A1: the at-limit IRET must succeed)"
assert H("esi") == 0x00020002, f"esi={last['esi']} != 0x00020002 (two #GPs, BOTH with error code 0 -- H-03)"
assert H("ecx") == 2,          f"ecx={last['ecx']} != 2 (A2/A3 faulted with ESP UNCHANGED -- H-02)"
assert H("ebp") == 0x002B0000, f"ebp={last['ebp']} != 0x002B0000 (case B: DS survived, ES nulled)"
assert H("ebx") == 0x00300020, f"ebx={last['ebx']} != 0x00300020 (case B: FS conforming + GS survived)"
print(f"  RTL final record        : edi=0xA1A1A1A1 esi=0x00020002 ecx=2 ebp=0x002B0000 ebx=0x00300020")
print(f"                          (at-limit IRET ok; two #GP(0); ESP preserved; case-B boundary)")
PYEOF
  # Count the core's +ven_faultlog records only.  A VEN_DBG_CORE build also
  # emits a `tb: FLT ...` observer line for the same delivery; the old
  # unanchored pattern counted both formats and falsely reported four faults
  # for the exact FPGA debug profile even though only two were delivered.
  GP0="$(grep -c '^\[FAULT\] vec=13 .*err=00000000' "$FLOG" || true)"
  GP40="$(grep -c '^\[FAULT\] vec=13 .*err=00000040' "$FLOG" || true)"
  echo "  fault log: #GP(0)=$GP0 (want 2: the IRET and the RETF)  #GP(0x40)=$GP40 (want 0: the pre-fix selector error code)"
  [[ "$GP0" == "2" ]] || { echo "FATAL: piretgp0: expected exactly two #GP(0) (A2 IRET + A3 RETF); see $FLOG"; exit 1; }
  [[ "$GP40" == "0" ]] || { echo "FATAL: piretgp0: #GP(0x40) is the pre-fix H-03 behaviour (selector as the error code)"; exit 1; }
  echo "  RTL-WITNESS-OK: #GP(0) with error code 0 at both returns, ESP preserved,"
  echo "                  at-limit IRET succeeds, case-B cleanup boundary correct"
  elif [[ "$TEST" == "pselnull" ]]; then
  PYTHONPATH="$REPO/verif/diff" "$PY" - "$WTR" <<'PYEOF'
import sys
import tracefmt as t
tr = t.read_trace(sys.argv[1])
last = tr.records[-1]
def H(k): return int(last[k], 16)
assert H("edi") == 0x0BABE001, f"edi={last['edi']} != 0x0BABE001 (case A: null-DS read must land on S1 at base 0, no #PF, NOT the poison base 0xA0000)"
assert H("esi") == 0x00010004, f"esi={last['esi']} != 0x00010004 (case B: the LDT-entry-0 far JMP succeeded; case C: error code 0x0004 -- TI preserved)"
assert H("ebp") == 0x010A0004, f"ebp={last['ebp']} != 0x010A0004 (case D: #TS(0x0004) raised in the OUTGOING context -- ESP at the fault == the pre-switch ESP, nothing moved)"
assert H("ebx") == 0x0000898B, f"ebx={last['ebx']} != 0x0000898B (case D: NO busy-byte writes -- TSS_D stays 0x89, TSS1 stays 0x8B)"
assert H("ecx") == 0x0BABE001, f"ecx={last['ecx']} != 0x0BABE001 (case E: the task-switch-staged null DS has base 0 -- task_e reads S1 through it, no #PF)"
print(f"  RTL final record        : edi=ecx=0x0BABE001 esi=0x00010004 ebp=0x010A0004 ebx=0x0000898B")
print(f"                          (null DS base 0 twice; LDT0 JMP ok + err 0x0004; outgoing-context #TS; no busy writes)")
PYEOF
  GP04="$(grep -c '^\[FAULT\] vec=13 .*err=00000004' "$FLOG" || true)"
  TS04="$(grep -c '^\[FAULT\] vec=10 .*err=00000004' "$FLOG" || true)"
  TS00="$(grep -c '^\[FAULT\] vec=10 .*err=00000000' "$FLOG" || true)"
  echo "  fault log: #GP(0x0004)=$GP04 (want 1: case C, OOB LDT selector, TI preserved)"
  echo "             #TS(0x0004)=$TS04 (want 1: case D, incoming LDTR TI violation)"
  echo "             #TS(0x0000)=$TS00 (want 0: the old {sel[15:3],3'b000} error form)"
  [[ "$GP04" == "1" ]] || { echo "FATAL: pselnull: case C must deliver exactly one #GP(0x0004) -- the OOB LDT selector's error code with TI preserved (0x0000 would be the old form; 0 would mean no fault); see $FLOG"; exit 1; }
  [[ "$TS04" == "1" ]] || { echo "FATAL: pselnull: case D must deliver exactly one #TS(0x0004) -- the incoming LDTR 0x0004 TI violation (0 would mean the LDTR was silently invalidated, the HEAD defect); see $FLOG"; exit 1; }
  [[ "$TS00" == "0" ]] || { echo "FATAL: pselnull: #TS(0x0000) is the old TI-clearing error form"; exit 1; }
  echo "  RTL-WITNESS-OK: null loads staged zeros with no GDT[0] access (no #PF,"
  echo "                  poison base never leaks), LDT entry 0 jumpable, error"
  echo "                  codes preserve TI, incoming LDTR 0x0004 is #TS(0x0004)"
  elif [[ "$TEST" == "ptswflt" ]]; then
  PYTHONPATH="$REPO/verif/diff" "$PY" - "$WTR" <<'PYEOF'
import sys
import tracefmt as t
tr = t.read_trace(sys.argv[1])
last = tr.records[-1]
def H(k): return int(last[k], 16)
assert H("edi") == 0x00007003, f"edi={last['edi']} != 0x00007003 (P1: the RO outgoing-save faults at CR2 page 0x7000, err 0x003, zero dwords landed)"
assert H("esi") == 0x0100A01C, f"esi={last['esi']} != 0x0100A01C (P2: the phase-1 outgoing save STANDS (resume EIP in the slot) and the incoming NP read faults at CR2 0xA01C)"
assert H("ebp") == 0x8A408A48, f"ebp={last['ebp']} != 0x8A408A48 (P3 #TS(0x40) + P4 #TS(0x48) raised in the OUTGOING context, espok=1, nothing moved)"
assert H("ebx") == 0x8B508B58, f"ebx={last['ebx']} != 0x8B508B58 (P4b/P4c: presence-only incoming CS/SS -> #NP(0x50)/#NP(0x58), outgoing context; type/privilege rank before presence, a presence-only failure is #NP not #TS)"
assert H("ecx") == 0x8B608A68, f"ecx={last['ecx']} != 0x8B608A68 (P4d #NP(0x60); P4e control: not-present DATA as CS -> #TS(0x68), the type check precedes presence)"
assert H("edx") == 0xBCE300F4, f"edx={last['edx']} != 0xBCE300F4 (P5a/P5b/P5c busy bytes: the outgoing descriptor NEVER becomes available mid-switch (p5a_run/p5b_run/p5c_run all busy); p5a_inc stays available (its set write faulted), p5b_inc/p5c_inc are busy-but-not-entered -- the recoverable state)"
assert H("eax") == 0x001E0042, f"eax={last['eax']} != 0x001E0042 (P5c: the CALL-form back-link store faults at incoming TSS offset 0, CR2 0x1E000, outgoing busy NOT cleared, pre-commit)"
print(f"  RTL final record        : edi=0x00007003 esi=0x0100A01C ebp=0x8A408A48 ebx=0x8B508B58")
print(f"                            ecx=0x8B608A68 edx=0xBCE300F4 eax=0x001E0042")
print(f"                          (P1 RO save #PF, nothing landed; P2 save stands; P3/P4 outgoing-context #TS;")
print(f"                           P4b-P4d presence-only #NP, P4e type-first #TS; busy order held)")
PYEOF
  PF03="$(grep -c '^\[FAULT\] vec=14 .*err=00000003' "$FLOG" || true)"
  PF00="$(grep -c '^\[FAULT\] vec=14 .*err=00000000' "$FLOG" || true)"
  TS40="$(grep -c '^\[FAULT\] vec=10 .*err=00000040' "$FLOG" || true)"
  TS48="$(grep -c '^\[FAULT\] vec=10 .*err=00000048' "$FLOG" || true)"
  TS68="$(grep -c '^\[FAULT\] vec=10 .*err=00000068' "$FLOG" || true)"
  NP50="$(grep -c '^\[FAULT\] vec=11 .*err=00000050' "$FLOG" || true)"
  NP58="$(grep -c '^\[FAULT\] vec=11 .*err=00000058' "$FLOG" || true)"
  NP60="$(grep -c '^\[FAULT\] vec=11 .*err=00000060' "$FLOG" || true)"
  TOT="$(grep -c '^\[FAULT\] vec=' "$FLOG" || true)"
  echo "  fault log: #PF(0x003)=$PF03 (want 4: P1/P5a/P5b/P5c write faults)  #PF(0x000)=$PF00 (want 1: P2 read NP)"
  echo "             #TS(0x0040)=$TS40 (want 1: P3 LDTR)  #TS(0x0048)=$TS48 (want 1: P4 system DS)  #TS(0x0068)=$TS68 (want 1: P4e type-first control)"
  echo "             #NP(0x0050)=$NP50 / #NP(0x0058)=$NP58 / #NP(0x0060)=$NP60 (want 1 each: P4b/P4c/P4d presence-only)  total=$TOT (want 11)"
  [[ "$PF03" == "4" ]] || { echo "FATAL: ptswflt: exactly four write-permission #PFs (P1/P5a/P5b/P5c); see $FLOG"; exit 1; }
  [[ "$PF00" == "1" ]] || { echo "FATAL: ptswflt: exactly one not-present read #PF (P2); see $FLOG"; exit 1; }
  [[ "$TS40" == "1" && "$TS48" == "1" && "$TS68" == "1" ]] || { echo "FATAL: ptswflt: one #TS each for 0x40 (P3 LDTR), 0x48 (P4 system DS), 0x68 (P4e type-first control); see $FLOG"; exit 1; }
  [[ "$NP50" == "1" && "$NP58" == "1" && "$NP60" == "1" ]] || { echo "FATAL: ptswflt: one #NP each for 0x50/0x58/0x60 (P4b/P4c/P4d presence-only); #TS here would be the pre-fix blanket-tsw_seg_bad behaviour; see $FLOG"; exit 1; }
  [[ "$TOT" == "11" ]] || { echo "FATAL: ptswflt: no other vector may fault; see $FLOG"; exit 1; }
  echo "  RTL-WITNESS-OK: every switch phase faults in the documented partial state"
  echo "                  (save-stands, outgoing-context #TS, presence-only #NP vs"
  echo "                  type-first #TS, busy never freed mid-switch, CALL back-link #PF)"
  elif [[ "$TEST" == "pxwrapm" ]]; then
  # The wrapped frame-probe ZERO-BYTES witness: m0..m5 scan every frame slot
  # against the 0xCC sentinel (the RTL must report ZERO written slots where
  # QEMU reports 13 -- the incremental-push oracle gap); m6 is terminal
  # (#PF -> #DF -> S_SHUTDOWN, the old V86 context intact, CR2 = the faulting
  # slot) because no #PF can be delivered back out of V86 without re-probing
  # the same wrapped TSS stack.
  PYTHONPATH="$REPO/verif/diff" "$PY" - "$WTR" <<'PYEOF'
import sys
import tracefmt as t
tr = t.read_trace(sys.argv[1])
last = tr.records[-1]
def H(k): return int(last[k], 16)
assert H("edi") == 0,          f"edi={last['edi']} != 0 (ZERO frame slots may be written by a rejected probe)"
assert H("esi") == 6,          f"esi={last['esi']} != 6 (m0..m5 must complete before the terminal m6)"
assert H("ecx") == 0,          f"ecx={last['ecx']} != 0 (no written-slot mask bits)"
assert H("ebp") == 0x5B,       f"ebp={last['ebp']} != 91 (every slot of m0..m5 was scanned)"
assert H("ebx") == 0,          f"ebx={last['ebx']} != 0 (m5 also clean)"
assert H("cr2") == 0x00090FF8, f"cr2={last['cr2']} != 0x00090FF8 (m6: the first denied-page slot in push order)"
assert H("ss")  == 0x2000,     f"ss={last['ss']} != 0x2000 (the OLD V86 SS -- the switch never committed)"
assert H("esp") == 0x8000,     f"esp={last['esp']} != 0x8000 (the OLD V86 ESP)"
assert (H("eflags") >> 17) & 1 == 1, f"eflags={last['eflags']}: VM cleared (the V86 context was left)"
print(f"  RTL final record        : zero written slots over 91 scanned, cr2=0x00090FF8,")
print(f"                            ss=0x2000 esp=0x8000 VM=1 (m6 terminal in the OLD V86 context)")
PYEOF
  PF2="$(grep -c '^\[FAULT\] vec=14 .*err=00000002' "$FLOG" || true)"
  GP60="$(grep -c '^\[FAULT\] vec=13 .*err=00000060' "$FLOG" || true)"
  DF="$(grep -c '^\[FAULT\] vec=8 ' "$FLOG" || true)"
  D2="$(grep -c '^\[FAULT\].*depth=2' "$FLOG" || true)"
  echo "  fault log: #PF(err=2)=$PF2 (want 8: 6 probes + m6 cascade x2)  #GP(0x60)=$GP60 (want 1)  #DF=$DF (want 0)  depth=2=$D2 (want 1)"
  [[ "$PF2" == "8" ]] || { echo "FATAL: pxwrapm: expected 8 supervisor-class #PFs (6 probes + 2 in the m6 cascade); see $FLOG"; exit 1; }
  [[ "$GP60" == "1" ]] || { echo "FATAL: pxwrapm: expected m1's #GP(0x60) trigger; see $FLOG"; exit 1; }
  [[ "$DF" == "0" && "$D2" == "1" ]] || { echo "FATAL: pxwrapm: the m6 cascade must escalate cleanly to the shutdown (no delivered #DF)"; exit 1; }
  echo "  RTL-WITNESS-OK: zero frame bytes on every denied page, m6 terminal with"
  echo "                  CR2/old-context intact, no escalation past #DF"
  elif [[ "$TEST" == "pxdplan" ]]; then
  # Frame page-plan probe (witness grading): C1 must leave ZERO slots written
  # and D=0 on the validated early page (validation is not a write), C3 must
  # D-mark both colliding pages pre-commit, and the +ven_frmpglog sequence
  # must show one probe beat per distinct page and no walk during any push.
  PLOG="$OUTDIR/$TEST.frmpglog"
  "$TB" --image "$IMG" --system --out /dev/null --max-insn "$MAXI" \
      --quiesce 400 +ven_faultlog +ven_frmpglog >"$PLOG" 2>&1 || true
  PYTHONPATH="$REPO/verif/diff" "$PY" - "$WTR" <<'PYEOF'
import sys
import tracefmt as t
tr = t.read_trace(sys.argv[1])
last = tr.records[-1]
def H(k): return int(last[k], 16)
assert H("edi") == 0,          f"edi={last['edi']} != 0 (ZERO frame slots may be written by a rejected probe)"
assert H("esi") == 2,          f"esi={last['esi']} != 2 (C1+C2 handled)"
assert H("ecx") == 0xC,        f"ecx={last['ecx']} != 0xC (C1: D=0 on the validated page; C3: D=1 on both after the D-mark pass)"
assert H("ebp") == 0x0009000E, f"ebp={last['ebp']} != 0x9000E (C1 CR2)"
assert H("ebx") == 0x00080012, f"ebx={last['ebx']} != 0x80012 (C2 CR2)"
print(f"  RTL final record        : edi=0 (zero bytes) esi=2 ecx=0xC (no D in validation;")
print(f"                            D-mark set both pages in C3) ebp=0x9000E ebx=0x80012 (CR2s)")
PYEOF
  "$PY" - "$PLOG" <<'PYEOF'
import re, sys
lines = [l for l in open(sys.argv[1]) if l.startswith("[FRMPG]")]
got = []
for l in lines:
    m = re.search(r"nslots=(\d+) npages=(\d+) val=(\d+) dm=(\d+) pushwalk=(\d+)", l)
    assert m, f"unparsable FRMPG line: {l}"
    got.append(tuple(int(m.group(i)) for i in range(1, 6)))
want = [
    (5,1,1,0,0),   # C1 int31 return
    (5,1,1,0,0),   # C2 int31 return
    (5,2,2,2,0),   # C3: 2-page validation + 2-beat D-mark, no push walk
    (5,1,1,0,0),   # C3 int31 return
    (5,1,1,0,0),   # C4: 32-bit int frame, one page
    (5,1,1,0,0),   # C4 int31 return
    (5,2,2,0,0),   # C5: 16-bit int frame, two colliding pages
    (5,1,1,0,0),   # C5 int31 return
    (9,3,3,0,0),   # C6: V86 9-slot frame, three pages
    (9,1,1,0,0),   # C6 int31 return (9-slot V86 frame on the clean stack)
    (35,3,3,0,0),  # C7: pcount=31 call gate, 35 slots -> 3 probe beats
    (5,1,1,0,0),   # C7 int31 return
]
for i, (g, w) in enumerate(zip(got, want)):
    assert g == w, f"FRMPG[{i}] = {g}, want {w}"
assert len(got) == len(want), f"FRMPG line count {len(got)} != {len(want)}"
print(f"  FRMPG sequence          : {len(got)} deliveries, one probe beat per distinct page,")
print(f"                            D-mark beats == plan pages when clean, pushwalk=0 everywhere")
PYEOF
  PF2="$(grep -c 'err=00000002' "$PLOG" || true)"
  TOT="$(grep -c 'err=' "$PLOG" || true)"
  echo "  fault log: #PF(err=2)=$PF2 (want 2: C1/C2)  total=$TOT (want 2)"
  [[ "$PF2" == "2" && "$TOT" == "2" ]] || { echo "FATAL: pxdplan: exactly the two probe faults may fire; see $PLOG"; exit 1; }
  echo "  RTL-WITNESS-OK: zero bytes + no D during validation, D-mark pre-commit,"
  echo "                  one probe beat per page, no push walks (DTLB-eviction proof)"
  fi
fi

echo
echo "SYS-GOLDEN-OK  ($OUT)"
