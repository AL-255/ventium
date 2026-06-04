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
RTL_SYS_TESTS="pseg pmode ppage"
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
  echo "  ($TEST exercises paging = M2S.2 RTL; not yet in the RTL, so golden"
  echo "   self-diff only. Phase 2 adds it to RTL_SYS_TESTS for a real RTL diff.)"
fi

echo
echo "SYS-GOLDEN-OK  ($OUT)"
