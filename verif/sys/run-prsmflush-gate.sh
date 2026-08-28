#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-prsmflush-gate.sh — executable-invalidation consumption + CONTRACT gate.
#
# prsmflush (verif/sys/tests/prsmflush/, see its manifest.json) proves that an
# executable invalidation (CR3 reload / INVLPG / INVD/WBINVD / A20 edge / RSM)
# beats CONSUMPTION (no fast-serve path may retire a line the flush is
# killing) AND honors the invalidation CONTRACT: at every flush edge the
# +ven_icflushlog sim probe (rtl/mem/icache.sv) must show the stale line's
# way occupancy (each case runs twice -- stale filled before vs after a
# same-set conflict line -- so both way placements are covered), both old
# valid bits zero one clock later, and only then the refill:
#
#   prsmflush.bin     cases B/I/D/C, fully differential vs the QEMU golden:
#                     B1/B2 remap a linear page to a different physical frame
#                     and reload CR3; I1/I2 the same via INVLPG; D1/D2 are
#                     INVD/WBINVD contract-only cases (the backing bytes do
#                     not change -- a CPU store would snoop-invalidate the
#                     line and test the wrong thing; the probe log carries the
#                     proof); C1/C2 disable A20 after filling the aliased
#                     line. The RTL side runs `--system --cosim` (the image
#                     toggles port 0x92; --cosim is the sanctioned io_* seam
#                     enable, retire/trace semantics identical).
#   prsmflush_smm.bin case A, WITNESS-graded: inside SMM a stub line is
#                     filled, its backing overwritten, the save-map resume EIP
#                     redirected at the stub, and RSM must refill (never serve
#                     the stale line). Two rounds place the stale line in
#                     opposite ways. No differential golden is possible (the
#                     qemu-system gdbstub single-step path masks SMI — the
#                     psmm oracle infeasibility), so grading is the RTL
#                     final-record witnesses + the probe log + the QEMU
#                     free-run exit status.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SYS="$ROOT/verif/sys"
REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
QSYS="$REFS/build/qemu/build-sys/qemu-system-i386"
GEN="$ROOT/verif/qemu-trace/gen_trace.py"
COMPARE="$ROOT/verif/diff/compare.py"
T="$SYS/tests/prsmflush"
TB="$ROOT/verif/tb/obj_dir/tb_ventium"
OUT="$ROOT/build/sys"
PORT="${PORT:-41287}"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUT"

echo "== prsmflush gate: executable invalidation must beat consumption =="

# --- 1. qemu-system-i386 (idempotent) + the images ---------------------------
bash "$SYS/build-qemu-system.sh" >/dev/null
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing"; exit 1; }
make -C "$T" >/dev/null
make -C "$ROOT/verif/tb" rtl >/dev/null 2>&1
[[ -x "$TB" ]] || { echo "FATAL: RTL TB $TB not built"; exit 1; }

# --- 2. both images run to the isa-debug-exit under qemu ---------------------
for IMG in "$T/prsmflush.bin" "$T/prsmflush_smm.bin"; do
  set +e
  timeout 20 "$QSYS" -display none -machine pc -m 32 \
      -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$IMG" >/dev/null 2>&1
  RC=$?
  set -e
  echo "  qemu free-run $(basename "$IMG"): exit $RC (expected 133)"
  [[ "$RC" == "133" ]] || { echo "PRSMFLUSH-GATE-FAIL ($(basename "$IMG") did not reach the isa-debug-exit)"; exit 1; }
done

# --- 3. cases B+C: differential vs the QEMU golden ----------------------------
GOLD="$OUT/prsmflush.sys.vtrace"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$T/prsmflush.bin" \
    --image-mode bios --out "$GOLD" --port "$PORT" --max-insn 6000
echo "  golden: $GOLD ($(wc -l < "$GOLD") lines)"

RTL_OUT="$OUT/prsmflush.rtl.sys.vtrace"
ICFL_LOG="$OUT/prsmflush.rtl.icfl.log"
"$TB" --system --cosim --image "$T/prsmflush.bin" --out "$RTL_OUT" \
    --max-insn 6000 --quiesce 800 +ven_icflushlog >"$ICFL_LOG" 2>&1 || true
echo "  RTL trace: $RTL_OUT ($(wc -l < "$RTL_OUT") lines)"
echo "  icache probe log: $ICFL_LOG ($(grep -c '\[ICFL\]' "$ICFL_LOG") probe lines)"
# the sim-only invalidation assertions must stay silent on every run
if grep -qE 'ICACHE/DUP-TAG|ICACHE/FLUSH' "$ICFL_LOG"; then
  echo "PRSMFLUSH-GATE-FAIL (an ICACHE assertion fired; see $ICFL_LOG)"; exit 1
fi

set +e
RDIFF_OUT="$("$PY" "$COMPARE" --mode func --all --max-report 8 "$GOLD" "$RTL_OUT" 2>/dev/null)"
RDIFF_RC=$?
set -e
echo "$RDIFF_OUT" | sed 's/^/  /'
[[ "$RDIFF_RC" == "0" ]] || { echo "PRSMFLUSH-GATE-FAIL (cases B+C DIVERGENT vs golden)"; exit 1; }
echo "  cases B+C: RTL system trace EQUIVALENT to the golden"

# Final-record witnesses (the discriminator values: B_NEW / C_NEW must be the
# LAST writer -- a single stale serve leaves the OLD value behind).
python3 - "$RTL_OUT" <<'PYEOF'
import sys, json
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith('{"vtrace"')]
last = recs[-1]
H = lambda k: int(last[k], 16)
assert H("edi") == 0xB0020002, f"edi={last['edi']} != 0xB0020002 (B_NEW: the post-CR3-flush fetch served a STALE line)"
assert H("esi") == 0xC0020002, f"esi={last['esi']} != 0xC0020002 (C_NEW: the post-A20-edge fetch served a STALE line)"
assert H("ebx") == 0xB0010001, f"ebx={last['ebx']} != 0xB0010001 (B_OLD fill proof missing)"
assert H("ebp") == 0xC0010001, f"ebp={last['ebp']} != 0xC0010001 (C_OLD fill proof missing)"
assert H("ecx") == 0xB0080008, f"ecx={last['ecx']} != 0xB0080008 (I2_NEW: the INVLPG/INVD cases left a wrong marker)"
assert H("edx") >> 16 == 0x600D, f"edx={last['edx']} != 0x600D.... (pass magic)"
assert len(recs) > 4000, f"only {len(recs)} records (anti-vacuity)"
print(f"  B+C final record: edi=0xB0020002 esi=0xC0020002 ecx=0xB0080008 ebx/ebp fill proofs ok ({len(recs)} records)")
PYEOF

# --- 3b. invalidation CONTRACT grading via the +ven_icflushlog probe ---------
# The probe (sim-only, rtl/mem/icache.sv) dumps, at every flush_all edge, the
# valid {set,way,tag} triples (pre), the same sets one clock later (post --
# the contract: both old valid bits zero before any refill), and every line
# allocation (fill). Each subcase owns a FRESH target line, so its tag names
# its flush event:
#   B1/B2 (CR3 reload)   tags 00400/00402 (linear 0x400000/0x402000)
#   I1/I2 (INVLPG)       tags 00404/00406 (linear 0x404000/0x406000)
#   D1/D2 (INVD/WBINVD)  tags 00408/0040a (linear 0x408000/0x40A000)
#   C1/C2 (A20 edge)     tags 00101/00103 (linear 0x101000/0x103000)
# For every tag: exactly one flush with the stale line resident, the set
# empty one clock later, and the refill only after that. Every pair must
# cover BOTH ways (the fill parity alternates the stale way by construction;
# this is the proof it happened).
python3 - "$ICFL_LOG" <<'PYEOF'
import sys, re
evs = []
for l in open(sys.argv[1]):
    m = re.match(r"\[ICFL\] pre set=(\d+) way=(\d+) tag=([0-9a-f]+)", l)
    if m: evs.append(("pre", int(m[1]), int(m[2]), m[3])); continue
    m = re.match(r"\[ICFL\] post set=(\d+) valid=([01]+)", l)
    if m: evs.append(("post", int(m[1]), m[2], None)); continue
    m = re.match(r"\[ICFL\] fill set=(\d+) way=(\d+) tag=([0-9a-f]+)", l)
    if m: evs.append(("fill", int(m[1]), int(m[2]), m[3])); continue

PAIRS = [("B (CR3 reload)",  "00400", "00402"),
         ("I (INVLPG)",      "00404", "00406"),
         ("D (INVD/WBINVD)", "00408", "0040a"),
         ("C (A20 edge)",    "00101", "00103")]

def grade_one(tag, label):
    # the FIRST flush event carrying this tag is its own case's flush (the
    # line only becomes resident at the case's stale fill; a later flush may
    # still print a leftover copy -- e.g. the A20-ON edge sees the alias
    # refill line -- which needs no separate grading)
    idx = [i for i, e in enumerate(evs) if e[0] == "pre" and e[1] == 0 and e[3] == tag]
    assert idx, f"{label}: no flush event with the stale line (tag {tag}) resident"
    i = idx[0]
    way = evs[i][2]
    post = next((k for k in range(i + 1, len(evs))
                 if evs[k][0] == "post" and evs[k][1] == 0), None)
    assert post is not None, f"{label}: no post-flush dump for set 0 after the tag-{tag} flush"
    assert set(evs[post][2]) == {"0"}, f"{label}: set 0 still valid one clock after the tag-{tag} flush (valid={evs[post][2]})"
    refill = next((k for k in range(i + 1, len(evs))
                   if evs[k][0] == "fill" and evs[k][1] == 0 and evs[k][3] == tag), None)
    assert refill is not None, f"{label}: tag {tag} never refilled after the flush"
    assert post < refill, f"{label}: the refill of tag {tag} landed BEFORE the post-flush empty proof"
    return way

for label, t1, t2 in PAIRS:
    w1, w2 = grade_one(t1, label + "/1"), grade_one(t2, label + "/2")
    assert {w1, w2} == {0, 1}, f"{label}: stale-line ways {w1}/{w2} -- both way placements required"
    print(f"  contract {label:18s}: tags {t1}/{t2}, stale ways {w1}/{w2}, set empty one clock after the flush, refill after")
PYEOF

# --- 4. case A (SMM/RSM): WITNESS grading, no differential --------------------
SMM_OUT="$OUT/prsmflush_smm.rtl.vtrace"
SMM_ICFL="$OUT/prsmflush_smm.rtl.icfl.log"
"$TB" --system --image "$T/prsmflush_smm.bin" --out "$SMM_OUT" \
    --max-insn 12000 --quiesce 400 +ven_icflushlog >"$SMM_ICFL" 2>&1 || true
if grep -qE 'ICACHE/DUP-TAG|ICACHE/FLUSH' "$SMM_ICFL"; then
  echo "PRSMFLUSH-GATE-FAIL (an ICACHE assertion fired in case A; see $SMM_ICFL)"; exit 1
fi
python3 - "$SMM_OUT" <<'PYEOF'
import sys, json
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith('{"vtrace"')]
last = recs[-1]
H = lambda k: int(last[k], 16)
assert H("edi") == 0x5A4D0002, f"edi={last['edi']} != 0x5A4D0002 (NEW32: the post-RSM fetch served the STALE SMM line)"
assert H("esi") == 0x5A4D0001, f"esi={last['esi']} != 0x5A4D0001 (OLD32: the in-SMM fill never executed)"
assert H("ebp") == 0x5A4D900D, f"ebp={last['ebp']} != 0x5A4D900D (RSM GPR restore broken)"
assert H("ebx") == 0x52455421, f"ebx={last['ebx']} != 0x52455421 'RET!' (the mainline never resumed)"
assert H("edx") >> 16 == 0x600D, f"edx={last['edx']} != 0x600D.... (pass magic)"
assert len(recs) > 300, f"only {len(recs)} records (anti-vacuity)"
print(f"  case A (SMM/RSM): edi=0x5A4D0002 (post-RSM refill executed the NEW stub) ({len(recs)} records)")
PYEOF

# --- 4b. case A contract: the RSM flush, BOTH way placements ------------------
# Two rounds (one dummy-fill parity flip apart); the stub's linear tag is
# 00040, set 0. The probe log must show the SMM-filled stub line resident at
# each RSM flush edge (ptag 00040 -- the unpaged SMM fetch), the set empty
# one clock later, and the refill after that with ptag 00080 (the resumed
# paged context's frame, proving the remap was re-walked) -- and the two
# rounds must place the stale line in different ways.
python3 - "$SMM_ICFL" <<'PYEOF'
import sys, re
evs = []
for l in open(sys.argv[1]):
    m = re.match(r"\[ICFL\] pre set=(\d+) way=(\d+) tag=([0-9a-f]+) ptag=([0-9a-f]+)", l)
    if m: evs.append(("pre", int(m[1]), int(m[2]), m[3], m[4])); continue
    m = re.match(r"\[ICFL\] post set=(\d+) valid=([01]+)", l)
    if m: evs.append(("post", int(m[1]), m[2], None, None)); continue
    m = re.match(r"\[ICFL\] fill set=(\d+) way=(\d+) tag=([0-9a-f]+) ptag=([0-9a-f]+)", l)
    if m: evs.append(("fill", int(m[1]), int(m[2]), m[3], m[4])); continue
idx = [i for i, e in enumerate(evs) if e[0] == "pre" and e[1] == 0 and e[3] == "00040" and e[4] == "00040"]
assert len(idx) == 2, f"case A: {len(idx)} RSM flush events with the SMM-filled stub line (tag/ptag 00040) resident, want 2"
ways = []
for i in idx:
    ways.append(evs[i][2])
    post = next((k for k in range(i + 1, len(evs))
                 if evs[k][0] == "post" and evs[k][1] == 0), None)
    assert post is not None, "case A: no post-flush dump for set 0 after the RSM flush"
    assert set(evs[post][2]) == {"0"}, f"case A: set 0 still valid one clock after the RSM flush (valid={evs[post][2]})"
    refill = next((k for k in range(i + 1, len(evs))
                   if evs[k][0] == "fill" and evs[k][1] == 0 and evs[k][3] == "00040"), None)
    assert refill is not None, "case A: the stub line never refilled after the RSM flush"
    assert post < refill, "case A: the stub refill landed BEFORE the post-flush empty proof"
    assert evs[refill][4] == "00080", f"case A: the refill's ptag is {evs[refill][4]}, not 00080 -- the resumed fetch did not re-walk the remapped page"
assert set(ways) == {0, 1}, f"case A: stale-line ways {sorted(set(ways))} across the two rounds -- both placements required"
print(f"  case A contract: 2 RSM flush events, stale ways {ways} (both), refill ptag 00040->00080 after the empty proof")
PYEOF

echo "PRSMFLUSH-GATE-OK"
