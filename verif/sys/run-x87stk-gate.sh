#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-x87stk-gate.sh — REVIEW1_Aug3 R2-H06: the x87 stack-fault matrix,
# extended 2026-08-04 for REVIEW_Aug4 A4-H01.
#
# px87stk (verif/sys/tests/px87stk/, see its manifest.json) exercises the full
# x87 stack-fault operation matrix in one 64 KiB BIOS image: seven faulting
# shapes {reg-form arith with an empty ST(i), FLD ST(i) empty source, FXCH
# empty partner, FCOM with empty, FSTP ST(0) of an empty stack, FCOMPP pop2
# over exactly one live register, push overflow past 8 deep} x {masked,
# unmasked}, plus the FXAM-on-empty control (masked and unmasked) = 16 cases;
# A4-H01 adds 14 more: the fixed-ST1 consumers the canonical build decodes
# (FSCALE / FPREM / FPREM1 with ST0 live ST1 empty), the S_FSTORE deferred
# shapes (FST m32 / FSTP m32 of an EMPTY ST0 -- masked stores the QNaN32
# 0xFFC00000, unmasked stores NOTHING), and FDIV ST0,ST(i) / FSQRT with empty
# operands (direct S_FEXEC path canonically, deferred S_FP_BUSY on the
# SRT_ITER pipe variants) = 30 cases, 14 unmasked #MF deliveries.
#
# px87stk2 (same directory) is the SECOND image, run ONLY on the
# obj_dir_x87stk_tr variant (+define+VEN_TRANSCENDENTAL +define+VEN_SRT_ITER
# +define+VEN_FPREM): the transcendental fixed-ST1 consumers FPATAN / FYL2X /
# FYL2XP1 (d_unknown HALT on the default build) and the S_FP_BUSY deferred
# FDIV/FSQRT shapes (both FDIV operand-emptiness forms) = 12 cases, 6 #MF.
#
# WHY A SELF-CHECK: QEMU 8.2.2 implements NO x87 stack faults at all (fpush()/
# fpop() in target/i386/tcg/fpu_helper.c never consult fptags; FPUS_SF is
# defined and used nowhere in the i386 target), so no golden is possible. The
# oracle is SDM Vol.1 8.5.1 / Table 8-4, asserted in-guest. Grading is the
# piretgp0 WITNESS pattern (run-sys-golden.sh step 7w): the functional run's
# final trace record must carry edi=0x42 (all checks passed), ebx=14 (one #MF
# per unmasked case), ecx=30 (all cases completed), edx[31:16]=0x600D (the
# pass magic; dx's low half is clobbered to 0xf4 by the exit `out`), and
# +ven_faultlog must show exactly 14 vec=16 deliveries and no other vector
# (px87stk2: edi=0x42, ebx=6, ecx=12, 6x vec=16).
#
# Cycle mode carries no GPRs in its trace records, so the cycle and FP-pipeline
# variants are graded by PC-STREAM IDENTITY against the functional run of the
# same image (the image is deterministic), plus the same faultlog assertion.
#
# NEGATIVE CONTROL (documented in manifest.json, not re-run here): the pre-fix
# HEAD build (detection on the slow arm only, no masked-response substitution)
# stops at check 0x01 in cycle mode (fast-arm cases undetected) and at 0x03 in
# functional mode (raw eval instead of the QNaN indefinite), and the 2026-08-04
# M2 deviation (FLD ST(i) of an empty source pushing the raw stale slot bits,
# fixed later that day by extending the fp_push_data QNaN substitution to the
# underflow push) stopped every variant at edi=0x07. The witnesses below are
# non-vacuous by construction: edi=0x42 requires all 60+ in-guest checks, and
# the seven vec=16 lines require the unmasked cases to have delivered.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TB="$ROOT/verif/tb"
T="$ROOT/verif/sys/tests/px87stk"
CANON="${TB_BIN:-$TB/obj_dir/tb_ventium}"
OUT="$ROOT/build/sys"
mkdir -p "$OUT"

echo "== x87 stack-fault gate (R2-H06 + REVIEW_Aug4 A4-H01): the px87stk/px87stk2 matrices =="
make -C "$T" >/dev/null
make -C "$TB" OBJDIR=obj_dir >/dev/null

run_tb () {  # <bin> <tag> <image> <extra flags...> ; writes $OUT/<imgbase>.<tag>.{vtrace,faultlog}
  local bin="$1" tag="$2" img="$3"; shift 3
  local base; base="$(basename "$img" .bin)"
  set +e
  timeout 180 "$bin" --system "$@" --image "$img" \
      --out "$OUT/$base.$tag.vtrace" --max-insn 4000 --quiesce 8000 \
      +ven_faultlog >"$OUT/$base.$tag.faultlog" 2>&1
  local rc=$?
  set -e
  [ "$rc" != 124 ] || { echo "X87STK-GATE-FAIL ($tag: the run HUNG)"; exit 1; }
}

fail=0

# --- 1. functional run: the witness grading --------------------------------
run_tb "$CANON" func "$T/px87stk.bin"
python3 - "$OUT/px87stk.func.vtrace" <<'PYEOF'
import sys, json
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith('{"vtrace"')]
last = recs[-1]
H = lambda k: int(last[k], 16)
assert H("edi") == 0x42,   f"edi={last['edi']} != 0x42 -- a check FAILED (the value is the failing check's code; see manifest.json witnesses)"
assert H("ebx") == 14,     f"ebx={last['ebx']} != 14 (one #MF per unmasked case)"
assert H("ecx") == 30,     f"ecx={last['ecx']} != 30 (all cases must complete)"
assert H("edx") >> 16 == 0x600D, f"edx={last['edx']} != 0x600D.... (pass magic; the low half is the 0xf4 exit port)"
assert len(recs) > 2000,   f"only {len(recs)} records -- the run stopped before the matrix completed (anti-vacuity)"
print(f"  func final record: edi=0x42 ebx=14 ecx=30 edx=0x600D00f4 ({len(recs)} records) -- all 30 cases pass")
PYEOF
V16=$(grep -c 'vec=16' "$OUT/px87stk.func.faultlog" || true)
VOT=$(grep -c 'vec=' "$OUT/px87stk.func.faultlog" || true)
echo "  fault log: vec=16 x$V16 (want 14), all vectors x$VOT (want 14 -- nothing else faults)"
[ "$V16" = 14 ] && [ "$VOT" = 14 ] || { echo "  FAIL the unmasked cases must deliver exactly one #MF each and nothing else may fault"; fail=1; }

# --- 2. cycle-mode + FP-pipeline variants: PC-stream identity ---------------
pc_identical () {  # <functag> <tag> [imgbase]
  local base="${3:-px87stk}"
  python3 - "$OUT/$base.$1.vtrace" "$OUT/$base.$2.vtrace" <<'PYEOF'
import sys, json
pcs = lambda p: [json.loads(l)['pc'] for l in open(p) if l.strip() and not l.startswith('{"vtrace"')]
f, c = pcs(sys.argv[1]), pcs(sys.argv[2])
assert f == c, f"PC stream diverges from the functional run ({len(f)} vs {len(c)} records)"
print(f"  {sys.argv[2].split('.')[-2]}: PC-stream identical to the functional run ({len(c)} records)")
PYEOF
}

run_tb "$CANON" cycle "$T/px87stk.bin" --cycle
pc_identical func cycle

make -C "$TB" rtl OBJDIR=obj_dir_x87stk_p1 VL_EXTRA_DEFINES='+define+VEN_FP_PIPE +define+VEN_SRT_ITER' >/dev/null
run_tb "$TB/obj_dir_x87stk_p1/tb_ventium" fppipe "$T/px87stk.bin" --cycle
pc_identical func fppipe

make -C "$TB" rtl OBJDIR=obj_dir_x87stk_p2 VL_EXTRA_DEFINES='+define+VEN_FP_PIPE +define+VEN_FP_PIPE2 +define+VEN_SRT_ITER' >/dev/null
run_tb "$TB/obj_dir_x87stk_p2/tb_ventium" fppipe2 "$T/px87stk.bin" --cycle
pc_identical func fppipe2

for tag in cycle fppipe fppipe2; do
  V16=$(grep -c 'vec=16' "$OUT/px87stk.$tag.faultlog" || true)
  VOT=$(grep -c 'vec=' "$OUT/px87stk.$tag.faultlog" || true)
  [ "$V16" = 14 ] && [ "$VOT" = 14 ] || { echo "  FAIL $tag fault log: vec=16 x$V16, all x$VOT (want 14/14)"; fail=1; }
done
echo "  fault logs identical in all four variants (14x vec=16, nothing else)"

# --- 3. A4-H01 variant-only cases: px87stk2 on the TR build -----------------
# VEN_TRANSCENDENTAL (FPATAN/FYL2X/FYL2XP1 decode; d_unknown HALT on the
# default build) + VEN_SRT_ITER (FDIV/FSQRT commit DEFERRED in S_FP_BUSY) +
# VEN_FPREM. func witnesses + faultlog; --cycle graded by PC-stream identity.
echo "== A4-H01 TR variant: px87stk2 (transcendental fixed-ST1 + S_FP_BUSY deferred) =="
make -C "$TB" rtl OBJDIR=obj_dir_x87stk_tr VL_EXTRA_DEFINES='+define+VEN_TRANSCENDENTAL +define+VEN_SRT_ITER +define+VEN_FPREM' >/dev/null
TR="$TB/obj_dir_x87stk_tr/tb_ventium"

run_tb "$TR" trfunc "$T/px87stk2.bin"
python3 - "$OUT/px87stk2.trfunc.vtrace" <<'PYEOF'
import sys, json
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith('{"vtrace"')]
last = recs[-1]
H = lambda k: int(last[k], 16)
assert H("edi") == 0x42,   f"edi={last['edi']} != 0x42 -- a check FAILED (the value is the failing check's code; see manifest.json px87stk2 witnesses)"
assert H("ebx") == 6,      f"ebx={last['ebx']} != 6 (one #MF per unmasked case)"
assert H("ecx") == 12,     f"ecx={last['ecx']} != 12 (all cases must complete)"
assert H("edx") >> 16 == 0x600D, f"edx={last['edx']} != 0x600D.... (pass magic; the low half is the 0xf4 exit port)"
assert len(recs) > 1500,   f"only {len(recs)} records -- the run stopped before the matrix completed (anti-vacuity)"
print(f"  tr func final record: edi=0x42 ebx=6 ecx=12 edx=0x600D00f4 ({len(recs)} records) -- all 12 cases pass")
PYEOF
V16=$(grep -c 'vec=16' "$OUT/px87stk2.trfunc.faultlog" || true)
VOT=$(grep -c 'vec=' "$OUT/px87stk2.trfunc.faultlog" || true)
echo "  tr fault log: vec=16 x$V16 (want 6), all vectors x$VOT (want 6)"
[ "$V16" = 6 ] && [ "$VOT" = 6 ] || { echo "  FAIL tr func fault log: vec=16 x$V16, all x$VOT (want 6/6)"; fail=1; }

run_tb "$TR" trcycle "$T/px87stk2.bin" --cycle
pc_identical trfunc trcycle px87stk2
V16=$(grep -c 'vec=16' "$OUT/px87stk2.trcycle.faultlog" || true)
VOT=$(grep -c 'vec=' "$OUT/px87stk2.trcycle.faultlog" || true)
[ "$V16" = 6 ] && [ "$VOT" = 6 ] || { echo "  FAIL tr cycle fault log: vec=16 x$V16, all x$VOT (want 6/6)"; fail=1; }
echo "  tr fault logs identical in both modes (6x vec=16, nothing else)"

# --- 4. the record/field-exact oracle masks DISCRIMINATE --------------------
# The four x87_stkflt corpus programs mask fstat/st* only inside measured
# record/field-exact sets (see their manifest.json ranges notes). Prove the
# comparator still DISCRIMINATES around tx_stack's allowed set (fstat n=20..27;
# per-record st* field lists n=20..35; zero-mask resync tail n=36..46):
#   (a) st* divergence BEFORE the allowed set          -> DIVERGENT
#   (b) st* divergence in an ALLOWED FIELD of an
#       allowed record                                 -> EQUIVALENT (the gap)
#   (c) st* divergence in a NON-allowed FIELD of the
#       SAME allowed record                            -> DIVERGENT
#   (d) st* divergence AFTER the final allowed record
#       (inside the zero-mask resync tail)             -> DIVERGENT
#   plus: fstat divergence BEFORE the allowed set      -> DIVERGENT
#   plus: the clean pair                               -> EQUIVALENT
# Only (b) and the clean pair may pass -- a program-wide or open-ended mask
# could not tell these apart. MSK is derived from the LIVE manifest with the
# same snippet verify_worker.sh uses, so the selftest cannot drift from the
# gate masks.
echo "== scoped oracle-mask discrimination (compare.py selftest) =="
TXMF="$ROOT/verif/tests/tx_stack/manifest.json"
TXMAX="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["max_insn"])' "$TXMF")"
# glob the golden for the manifest's CURRENT max_insn (stale entries for the
# same source at other --max-insn values may share the cache)
TXG=$(ls "$ROOT"/build/golden-cache/$(sha1sum "$ROOT"/verif/tests/tx_stack/tx_stack.s | cut -d' ' -f1).*.func.x871.max"$TXMAX".vtrace 2>/dev/null | while read -r g; do
  # pick the golden whose first-record esp matches the RTL trace (the live corpus one)
  if [ "$(head -2 "$g" | tail -1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["esp"])')" = \
       "$(head -2 "$ROOT"/build/verify/tx_stack.func_rtl.vtrace | tail -1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["esp"])')" ]; then echo "$g"; fi
done | head -1)
TXR="$ROOT/build/verify/tx_stack.func_rtl.vtrace"
if [ -z "$TXG" ] || [ ! -f "$TXR" ]; then
  echo "  SKIP: tx_stack golden/RTL trace not in the cache yet (run make verify first)"
else
  MSK="$(python3 - "$ROOT/verif/tests/tx_stack/manifest.json" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
fr, pr = m.get("x87_stkflt_fstat_ranges"), m.get("x87_stkflt_fpr_ranges")
def fmt(r):
    s = f"{r[0]}:{'' if len(r) < 2 or r[1] is None else r[1]}"
    if len(r) >= 3 and r[2]:
        s += f"={r[2]}"
    return s
args = []
if fr:
    args.append("--mask-fstat-exc 0x4741")
    args += [f"--mask-fstat-range {fmt(r)}" for r in fr]
if pr:
    args += [f"--mask-fpr-range {fmt(r)}" for r in pr]
print(" ".join(args))
PYEOF
)"
  python3 - "$TXR" <<'PYEOF'
import json, sys
lines = open(sys.argv[1]).read().splitlines()
def fr(line, field, val):
    r = json.loads(line); r[field] = val; return json.dumps(r)
# tx_stack record map: fnop n=0 ... fstp pops n=20..27 (allowed), resync
# refill n=28..35 (allowed, rotating slots), tail n=36..46 (ZERO masks).
cases = {k: [] for k in ('a_before', 'b_allowed', 'c_nonallowed', 'd_after', 'fstat_before')}
for l in lines:
    if l.startswith('{"vtrace"') or not l.strip():
        for v in cases.values(): v.append(l)
        continue
    n = json.loads(l)['n']
    cases['a_before'].append(    fr(l, 'st2', '0x00010000000000000000') if n == 5  else l)
    cases['b_allowed'].append(   fr(l, 'st0', '0x00010000000000000000') if n == 27 else l)
    cases['c_nonallowed'].append(fr(l, 'st1', '0x00010000000000000000') if n == 27 else l)
    cases['d_after'].append(     fr(l, 'st0', '0x00010000000000000000') if n == 40 else l)
    cases['fstat_before'].append(fr(l, 'fstat', '0x000008ff')            if n == 10 else l)
for name, data in cases.items():
    open(f'/tmp/x87stk_sc_{name}.vtrace', 'w').write('\n'.join(data) + '\n')
PYEOF
  CMP="$ROOT/verif/diff/compare.py"
  # (the injected cases are EXPECTED to diverge -- compare.py exits 1 then,
  # and pipefail would otherwise abort the gate on its own negative control;
  # the trailing `|| true` keeps a zero grep count from aborting under set -e)
  R0=$(( python3 "$CMP" --mode func $MSK "$TXG" "$TXR" || true ) | grep -c 'RESULT: EQUIVALENT' || true)
  RA=$(( python3 "$CMP" --mode func $MSK "$TXG" /tmp/x87stk_sc_a_before.vtrace || true ) | grep -c 'RESULT: DIVERGENT' || true)
  RB=$(( python3 "$CMP" --mode func $MSK "$TXG" /tmp/x87stk_sc_b_allowed.vtrace || true ) | grep -c 'RESULT: EQUIVALENT' || true)
  RC_=$(( python3 "$CMP" --mode func $MSK "$TXG" /tmp/x87stk_sc_c_nonallowed.vtrace || true ) | grep -c 'RESULT: DIVERGENT' || true)
  RD=$(( python3 "$CMP" --mode func $MSK "$TXG" /tmp/x87stk_sc_d_after.vtrace || true ) | grep -c 'RESULT: DIVERGENT' || true)
  RF=$(( python3 "$CMP" --mode func $MSK "$TXG" /tmp/x87stk_sc_fstat_before.vtrace || true ) | grep -c 'RESULT: DIVERGENT' || true)
  echo "  clean=EQUIV:$R0 (a)before=DIVERG:$RA (b)allowed-field=EQUIV:$RB (c)nonallowed-field=DIVERG:$RC_ (d)after-tail=DIVERG:$RD fstat-before=DIVERG:$RF (want 1/1/1/1/1/1)"
  [ "$R0" = 1 ] && [ "$RA" = 1 ] && [ "$RB" = 1 ] && [ "$RC_" = 1 ] && [ "$RD" = 1 ] && [ "$RF" = 1 ] \
      || { echo "  FAIL the scoped mask does not discriminate"; fail=1; }
fi

# --- 5. narrowing-store stack-fault matrix: px87stk3 ------------------------
# Every decoded narrowing-store form x {masked,unmasked} on an empty ST0:
# masked stores complete with the destination-specific indefinite (QNaN32 /
# QNaN64 / integer min-signed / packed-BCD indefinite), unmasked stores
# commit nothing (destination poison untouched, one #MF each). Case B1 pins
# the suppressed-FBSTP engine launch: an unmasked FBSTP of an empty ST0
# retires suppressed, FNCLEX (non-waiting, no FWAIT) clears the pending #MF
# state, +0.0 is loaded, and a second FBSTP follows within the engine's
# ~60-clock busy window -- the stored bytes must be the conversion of the NEW
# value (all zero), not the suppressed op's stale-slot conversion. Grading is
# the same witness pattern: edi=0x42, ebx=10 (#MF count), ecx=21 (cases),
# edx[31:16]=0x600D, 10x vec=16 in the fault log and no other vector. Runs on
# the canonical build (the masked-response substitution is shared RTL) and on
# the two dedicated store-path builds: the iterative-BCD engine (unmasked
# FBSTP must retire suppressed without launching the engine) and the
# PS-trapped x87 build (the PS service answers every trap with one fixed
# computation; masked stores discard the PS result for the indefinite, so the
# image deliberately uses only PL-resident x87 ops). The PS-trap build needs
# the TB's trap service compiled in, so its CFLAGS add -DVEN_FPTRAP.
echo "== narrowing-store matrix: px87stk3 (canonical) =="

px87stk3_grade () {  # <functrace> <faultlog> <label>
  python3 - "$1" <<'PYEOF'
import sys, json
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith('{"vtrace"')]
last = recs[-1]
H = lambda k: int(last[k], 16)
assert H("edi") == 0x42,   f"edi={last['edi']} != 0x42 -- a check FAILED (the value is the failing check's code; see manifest.json px87stk3 witnesses)"
assert H("ebx") == 10,     f"ebx={last['ebx']} != 10 (one #MF per unmasked case)"
assert H("ecx") == 21,     f"ecx={last['ecx']} != 21 (all cases must complete)"
assert H("edx") >> 16 == 0x600D, f"edx={last['edx']} != 0x600D.... (pass magic; the low half is the 0xf4 exit port)"
assert len(recs) > 1500,   f"only {len(recs)} records -- the run stopped before the matrix completed (anti-vacuity)"
print(f"  func final record: edi=0x42 ebx=10 ecx=21 edx=0x600D00f4 ({len(recs)} records) -- all 21 cases pass")
PYEOF
  [ $? = 0 ] || return 1
  local v16 vot
  v16=$(grep -c 'vec=16' "$2" || true)
  vot=$(grep -c 'vec=' "$2" || true)
  echo "  fault log: vec=16 x$v16 (want 10), all vectors x$vot (want 10 -- nothing else faults)"
  [ "$v16" = 10 ] && [ "$vot" = 10 ]
}

run_tb "$CANON" func "$T/px87stk3.bin"
px87stk3_grade "$OUT/px87stk3.func.vtrace" "$OUT/px87stk3.func.faultlog" || { echo "  FAIL px87stk3 canonical func"; fail=1; }
run_tb "$CANON" cycle "$T/px87stk3.bin" --cycle
pc_identical func cycle px87stk3
V16=$(grep -c 'vec=16' "$OUT/px87stk3.cycle.faultlog" || true)
VOT=$(grep -c 'vec=' "$OUT/px87stk3.cycle.faultlog" || true)
[ "$V16" = 10 ] && [ "$VOT" = 10 ] || { echo "  FAIL px87stk3 cycle fault log: vec=16 x$V16, all x$VOT (want 10/10)"; fail=1; }

echo "== narrowing-store matrix: px87stk3 (iterative-BCD build) =="
make -C "$TB" rtl OBJDIR=obj_dir_x87stk_bcd VL_EXTRA_DEFINES='+define+VEN_BCD_ITER' >/dev/null
BCD="$TB/obj_dir_x87stk_bcd/tb_ventium"
run_tb "$BCD" bcdfunc "$T/px87stk3.bin" +ven_bcdlog
px87stk3_grade "$OUT/px87stk3.bcdfunc.vtrace" "$OUT/px87stk3.bcdfunc.faultlog" || { echo "  FAIL px87stk3 iterative-BCD func"; fail=1; }
run_tb "$BCD" bcdcycle "$T/px87stk3.bin" --cycle +ven_bcdlog
pc_identical bcdfunc bcdcycle px87stk3
V16=$(grep -c 'vec=16' "$OUT/px87stk3.bcdcycle.faultlog" || true)
VOT=$(grep -c 'vec=' "$OUT/px87stk3.bcdcycle.faultlog" || true)
[ "$V16" = 10 ] && [ "$VOT" = 10 ] || { echo "  FAIL px87stk3 iterative-BCD cycle fault log: vec=16 x$V16, all x$VOT (want 10/10)"; fail=1; }

# Engine-start accounting (+ven_bcdlog): exactly ONE accepted ven_bcd start per
# VALID FBSTP execution. px87stk3 executes two valid FBSTPs -- the masked M10
# (the engine runs and its output is discarded for the packed-BCD indefinite)
# and B1's re-issued FBSTP of +0.0 -- so the count must be 2 in both modes. The
# two SUPPRESSED FBSTPs (U10 and B1's first) must add ZERO starts: a suppressed
# op launching the engine in the background is exactly the defect case B1 pins
# (the second FBSTP's start would be ignored while busy and it would consume
# the first op's done/result).
for tag in bcdfunc bcdcycle; do
  BCDN=$(sed -n 's/^\[BCDLOG\] ven_bcd engine starts: \([0-9][0-9]*\)$/\1/p' "$OUT/px87stk3.$tag.faultlog")
  echo "  +ven_bcdlog ($tag): ven_bcd engine starts = ${BCDN:-<missing>} (want 2: M10 masked + B1 re-issue; the two suppressed FBSTPs add none)"
  [ "$BCDN" = 2 ] || { echo "  FAIL px87stk3 iterative-BCD $tag engine-start count"; fail=1; }
done

# px87stk on the same build (cheap: only the BCD engine differs there, and
# the first image already carries the m32 store cases).
run_tb "$BCD" bcd "$T/px87stk.bin"
python3 - "$OUT/px87stk.bcd.vtrace" <<'PYEOF'
import sys, json
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith('{"vtrace"')]
last = recs[-1]
H = lambda k: int(last[k], 16)
assert H("edi") == 0x42 and H("ebx") == 14 and H("ecx") == 30 and H("edx") >> 16 == 0x600D, \
    f"px87stk on the iterative-BCD build: edi={last['edi']} ebx={last['ebx']} ecx={last['ecx']} edx={last['edx']}"
print(f"  px87stk func on the iterative-BCD build: edi=0x42 ebx=14 ecx=30 ({len(recs)} records) -- all 30 cases pass")
PYEOF
[ $? = 0 ] || fail=1
V16=$(grep -c 'vec=16' "$OUT/px87stk.bcd.faultlog" || true)
VOT=$(grep -c 'vec=' "$OUT/px87stk.bcd.faultlog" || true)
[ "$V16" = 14 ] && [ "$VOT" = 14 ] || { echo "  FAIL px87stk iterative-BCD fault log: vec=16 x$V16, all x$VOT (want 14/14)"; fail=1; }

echo "== narrowing-store matrix: px87stk3 (PS-trapped x87 build) =="
make -C "$TB" rtl OBJDIR=obj_dir_x87stk_psall VL_EXTRA_DEFINES='+define+VEN_FP_PS_ALL +define+VEN_FPTRAP' \
    VL_CFLAGS="-I$TB -std=c++17 -DVEN_FPTRAP" >/dev/null
PSA="$TB/obj_dir_x87stk_psall/tb_ventium"
run_tb "$PSA" psfunc "$T/px87stk3.bin"
px87stk3_grade "$OUT/px87stk3.psfunc.vtrace" "$OUT/px87stk3.psfunc.faultlog" || { echo "  FAIL px87stk3 PS-trap func"; fail=1; }
run_tb "$PSA" pscycle "$T/px87stk3.bin" --cycle
pc_identical psfunc pscycle px87stk3
V16=$(grep -c 'vec=16' "$OUT/px87stk3.pscycle.faultlog" || true)
VOT=$(grep -c 'vec=' "$OUT/px87stk3.pscycle.faultlog" || true)
[ "$V16" = 10 ] && [ "$VOT" = 10 ] || { echo "  FAIL px87stk3 PS-trap cycle fault log: vec=16 x$V16, all x$VOT (want 10/10)"; fail=1; }

if [ "$fail" = 0 ]; then
  echo "X87STK-GATE-OK"
  exit 0
fi
echo "X87STK-GATE-FAIL"
exit 1
