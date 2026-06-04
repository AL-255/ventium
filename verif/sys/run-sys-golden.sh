#!/usr/bin/env bash
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
INTR_TESTS="pintr pfault"
XPRIV_TESTS="pcpl"
TASK_TESTS="ptask"

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
#                 selectors + GPRs + eflags + eip). The HARDWARE TASK SWITCH (CALL/
#                 JMP to a TSS / task gate = the "ptask" sibling) is the gnarliest
#                 piece and is DEFERRED — ptask stays self-diff-only (documented).
RTL_SYS_TESTS="pseg pmode ppage pintr pfault pcpl"
if echo " $RTL_SYS_TESTS " | grep -q " $TEST "; then
  say "7. RTL (Producer C) --system sys-diff vs golden (segmentation/paging gate)"
  TB="$REPO/verif/tb/obj_dir/tb_ventium"
  make -C "$REPO/verif/tb" rtl >/dev/null 2>&1
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
else
  say "7. RTL --system sys-diff: SKIPPED for '$TEST'"
  if echo " $INTR_TESTS " | grep -q " $TEST "; then
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
  else
    echo "  ($TEST exercises paging = M2S.2 RTL; not yet in the RTL, so golden"
    echo "   self-diff only. Phase 2 adds it to RTL_SYS_TESTS for a real RTL diff.)"
  fi
fi

echo
echo "SYS-GOLDEN-OK  ($OUT)"
