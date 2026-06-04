#!/usr/bin/env bash
# =============================================================================
# verif/errata/run-m6.sh -- Ventium M6 errata self-check gate (make m6).
#
# Reproduces four DOCUMENTED Pentium (P5/P54C) silicon errata behind the core's
# errata-enable flag (DEFAULT OFF) and SELF-CHECKS each against its documented
# behavior. There is NO differential oracle for errata (QEMU computes the CORRECT
# answer, not the buggy P5 result), so every check below asserts the value the
# Intel Specification Update documents -- with the flag ON for the defect and
# with the flag OFF for the clean (QEMU-matching) result.
#
#   1. FDIV / SRT divide flaw   (Erratum 23, 242480-022 p.78)
#   2. FIST/FISTP overflow      (Erratum 20, 242480-022 p.75)
#   3. F00F LOCK CMPXCHG8B reg  hang (Erratum 81, 242480-041 p.51)
#   4. MOV moffs A2/A3 non-pair (Erratum 59, 242480-022 p.99)
#
# Each errata bit (errata_en[3:0], --errata mask): [0]=FDIV [1]=FIST [2]=F00F
# [3]=MOFFS. The HARD complement (clean core stays GREEN) is `make verify`, run
# separately; this script asserts the ON behavior + the OFF behavior per test.
#
# Usage:  bash verif/errata/run-m6.sh   (or: make m6)
# Exit 0 iff every documented self-check passes.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TB_DIR="$ROOT/verif/tb"
TB_BIN="$TB_DIR/obj_dir/tb_ventium"
ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
TRACEDIR="$ROOT/build/m6"
PY="${PYTHON:-python3}"
CC="${CC:-gcc}"
CFLAGS="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext=0x08048000"
LOAD=0x08048000

mkdir -p "$TRACEDIR"
PASS=0; FAIL=0
declare -a RESULTS

say()  { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '    PASS  %s\n' "$*"; PASS=$((PASS+1)); RESULTS+=("PASS  $*"); }
bad()  { printf '    FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); RESULTS+=("FAIL  $*"); }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 2; }

# ---- prerequisites ----------------------------------------------------------
say "M6 errata self-check gate -- environment"
[ -x "$TB_BIN" ] || {
    printf '    building RTL testbench (verif/tb)...\n'
    make -C "$TB_DIR" >"$TRACEDIR/tb_build.log" 2>&1 || die "TB build failed (see $TRACEDIR/tb_build.log)"
}
[ -x "$TB_BIN" ]   || die "tb_ventium not found: $TB_BIN"
[ -f "$ELF2FLAT" ] || die "elf2flat.py missing: $ELF2FLAT"
command -v "$CC" >/dev/null 2>&1 || die "C compiler not found: $CC"
printf '    tb_ventium : %s\n' "$TB_BIN"
printf '    tracedir   : %s\n' "$TRACEDIR"

# ---- build one test ELF + flat ----------------------------------------------
build_test() {  # <name>
    local n="$1" d="$SCRIPT_DIR/$1"
    "$CC" $CFLAGS -o "$d/$n.elf" "$d/$n.s" \
        || die "assemble $n failed"
    "$PY" "$ELF2FLAT" "$d/$n.elf" --out "$d/$n.flat" --base "$LOAD" >/dev/null 2>&1 \
        || die "flatten $n failed"
}

# ---- run the TB; echoes the trace path; stderr captured to <out>.log --------
run_tb() {  # <name> <out-tag> <extra-args...>
    local n="$1" tag="$2"; shift 2
    local out="$TRACEDIR/${n}_${tag}.vtrace"
    "$TB_BIN" --image "$SCRIPT_DIR/$n/$n.flat" --load "$LOAD" --entry "$LOAD" \
        --out "$out" "$@" >"$TRACEDIR/${n}_${tag}.log" 2>&1
    echo "$out"
}

# field of the LAST trace record (func/x87 mode)
last_field() {  # <trace> <field>
    PYTHONPATH="$ROOT/verif/diff" "$PY" - "$1" "$2" <<'PY'
import sys, tracefmt
t = tracefmt.read_trace(sys.argv[1])
print(t.records[-1][sys.argv[2]] if t.records else "")
PY
}

# =============================================================================
# 1. FDIV / SRT divide flaw (Erratum 23). We reproduce the PUBLISHED failing
#    operand (the spec's fallback path -- Intel never published per-operand
#    flawed bits, so an arbitrary operand has no oracle). Self-check the floatx80
#    st0 quotient of the canonical public pair 4195835.0 / 3145727.0:
#      errata ON  -> documented FLAWED value (1.3337390689..., floatx80
#                    significand 0xAAB7F6392A768800).
#      errata OFF -> CORRECT value (1.3338204491..., significand 0xAABAA0E3E35A14BD).
#    Plus a NEGATIVE control (err_fdiv_neg): the model must NOT fabricate a flaw
#    for any non-published operand -- including a divisor that DOES hit the
#    documented SRT trigger pattern. Both control divides give ON == OFF (clean).
# =============================================================================
say "1. FDIV / SRT divide flaw (Erratum 23)  -- canonical 4195835.0/3145727.0"
build_test err_fdiv
FDIV_FLAWED="0x3fffaab7f6392a768800"   # documented flawed quotient (floatx80)
FDIV_CLEAN="0x3fffaabaa0e3e35a14bd"    # correct quotient (= QEMU/M3, floatx80)
tr=$(run_tb err_fdiv on  --x87 --errata 0x1 --max-insn 20); ON_ST0=$(last_field "$tr" st0)
tr=$(run_tb err_fdiv off --x87            --max-insn 20); OFF_ST0=$(last_field "$tr" st0)
printf '    errata ON  st0 = %s\n    errata OFF st0 = %s\n' "$ON_ST0" "$OFF_ST0"
[ "$ON_ST0"  = "$FDIV_FLAWED" ] && ok "FDIV errata ON  -> documented flawed quotient $FDIV_FLAWED" \
                                 || bad "FDIV errata ON: st0=$ON_ST0 expected flawed $FDIV_FLAWED"
[ "$OFF_ST0" = "$FDIV_CLEAN"  ] && ok "FDIV errata OFF -> correct quotient $FDIV_CLEAN (matches QEMU)" \
                                 || bad "FDIV errata OFF: st0=$OFF_ST0 expected correct $FDIV_CLEAN"

# Negative control: no fabricated flaw for non-published operands. st1 uses the
# triggering divisor 3145727.0 with a DIFFERENT dividend (hits the documented
# trigger, but is NOT the published pair -> must stay clean); st0 uses a non-
# triggering divisor (3.0). Both must be bit-identical errata ON vs OFF.
say "1b. FDIV no-fabrication negative control  -- trigger-but-unpublished + clean"
build_test err_fdiv_neg
tr=$(run_tb err_fdiv_neg on  --x87 --errata 0x1 --max-insn 30)
NEG_ON_ST0=$(last_field "$tr" st0);  NEG_ON_ST1=$(last_field "$tr" st1)
tr=$(run_tb err_fdiv_neg off --x87            --max-insn 30)
NEG_OFF_ST0=$(last_field "$tr" st0); NEG_OFF_ST1=$(last_field "$tr" st1)
printf '    trigger-divisor (unpublished) st1: ON=%s OFF=%s\n' "$NEG_ON_ST1" "$NEG_OFF_ST1"
printf '    non-triggering divisor        st0: ON=%s OFF=%s\n' "$NEG_ON_ST0" "$NEG_OFF_ST0"
{ [ -n "$NEG_ON_ST1" ] && [ "$NEG_ON_ST1" = "$NEG_OFF_ST1" ]; } \
    && ok "FDIV trigger-divisor-but-unpublished -> ON == OFF (NO fabricated flaw)" \
    || bad "FDIV neg-ctrl: triggering-divisor pair differs ON ($NEG_ON_ST1) vs OFF ($NEG_OFF_ST1)"
{ [ -n "$NEG_ON_ST0" ] && [ "$NEG_ON_ST0" = "$NEG_OFF_ST0" ]; } \
    && ok "FDIV non-triggering divisor -> ON == OFF (clean, unaffected)" \
    || bad "FDIV neg-ctrl: non-triggering divide differs ON ($NEG_ON_ST0) vs OFF ($NEG_OFF_ST0)"

# =============================================================================
# 2. FIST/FISTP overflow (Erratum 20). Operand 4294967295.5 (the documented
#    32-bit/nearest affected operand) -> FISTP m32, stored value witnessed in ESI
#    and the FPU status word in EDI:
#      errata ON  -> ESI == 0x00000000 (buggy zero), IE (status bit0) == 0.
#      errata OFF -> ESI == 0x80000000 (integer-indefinite), IE == 1.
# =============================================================================
say "2. FIST/FISTP overflow undetected (Erratum 20)  -- operand 4294967295.5"
build_test err_fist
tr=$(run_tb err_fist on  --x87 --errata 0x2 --max-insn 30)
ON_RES=$(last_field "$tr" esi);  ON_SW=$(last_field "$tr" edi)
tr=$(run_tb err_fist off --x87            --max-insn 30)
OFF_RES=$(last_field "$tr" esi); OFF_SW=$(last_field "$tr" edi)
ON_IE=$(( $(printf '%d' "$ON_SW")  & 1 )); OFF_IE=$(( $(printf '%d' "$OFF_SW") & 1 ))
printf '    errata ON  result=%s IE=%d\n    errata OFF result=%s IE=%d\n' \
       "$ON_RES" "$ON_IE" "$OFF_RES" "$OFF_IE"
{ [ "$ON_RES" = "0x00000000" ] && [ "$ON_IE" = "0" ]; } \
    && ok "FIST errata ON  -> stores ZERO, IE not set (documented Actual response)" \
    || bad "FIST errata ON: result=$ON_RES IE=$ON_IE expected 0x00000000 / IE=0"
{ [ "$OFF_RES" = "0x80000000" ] && [ "$OFF_IE" = "1" ]; } \
    && ok "FIST errata OFF -> integer-indefinite 0x80000000, IE set (Expected response)" \
    || bad "FIST errata OFF: result=$OFF_RES IE=$OFF_IE expected 0x80000000 / IE=1"

# =============================================================================
# 3. F00F LOCK CMPXCHG8B reg-dst hang (Erratum 81). The invalid F0 0F C7 C9 form:
#      errata ON  -> core HANGS (TB prints "CPU HUNG ... Erratum 81").
#      errata OFF -> loud HALT, NO hang.
#    Plus the valid MEMORY form must NOT hang even with the flag on.
# =============================================================================
say "3. F00F: LOCK CMPXCHG8B register-destination hang (Erratum 81)"
build_test err_f00f
build_test err_f00f_mem
LOG_ON="$TRACEDIR/err_f00f_on.log"; LOG_OFF="$TRACEDIR/err_f00f_off.log"
run_tb err_f00f on  --errata 0x4 --max-insn 30 --quiesce 40 >/dev/null
run_tb err_f00f off              --max-insn 30 --quiesce 40 >/dev/null
LOG_MEM="$TRACEDIR/err_f00f_mem_on.log"
run_tb err_f00f_mem on --errata 0x4 --max-insn 30 --quiesce 40 >/dev/null
grep -q "CPU HUNG" "$LOG_ON" \
    && ok "F00F errata ON  -> reg-dst LOCK CMPXCHG8B HANGS the core (documented)" \
    || bad "F00F errata ON: core did not hang (no 'CPU HUNG' in $LOG_ON)"
grep -q "CPU HUNG" "$LOG_OFF" \
    && bad "F00F errata OFF: core hung but should HALT loudly ($LOG_OFF)" \
    || ok "F00F errata OFF -> invalid opcode HALTs loudly, NO hang"
grep -q "CPU HUNG" "$LOG_MEM" \
    && bad "F00F: VALID memory CMPXCHG8B hung (must not) ($LOG_MEM)" \
    || ok "F00F errata ON  -> VALID memory CMPXCHG8B does NOT hang (only reg-dst does)"

# =============================================================================
# 4. MOV moffs A2/A3 fails to pair (Erratum 59). Cycle trace: the A3 store
#    (pc 0x08048009) is followed by an EAX-using MOV (pc 0x0804800e):
#      errata OFF -> that MOV is PAIRED (pipe=V, paired=true).
#      errata ON  -> that MOV is NOT paired (pipe=U, paired=false).
# =============================================================================
say "4. MOV moffs (A2/A3) fails to pair (Erratum 59)  -- cycle gate"
build_test err_moffs
MOFFS_FOLLOWER="0x0804800e"   # the EAX-using MOV right after the A3 store

# paired?(trace, pc) -> "1" if that pc retired with paired=true (V member), else "0"
paired_at() {  # <trace> <pc>
    PYTHONPATH="$ROOT/verif/diff" "$PY" - "$1" "$2" <<'PY'
import sys, tracefmt
t = tracefmt.read_trace(sys.argv[1]); pc = sys.argv[2].lower()
hit = [r for r in t.records if r["pc"].lower() == pc]
print("1" if (hit and bool(hit[-1]["paired"]) and hit[-1]["pipe"] == "V") else "0")
PY
}
tr=$(run_tb err_moffs off --cycle --max-insn 30); OFF_P=$(paired_at "$tr" "$MOFFS_FOLLOWER")
tr=$(run_tb err_moffs on  --cycle --errata 0x8 --max-insn 30); ON_P=$(paired_at "$tr" "$MOFFS_FOLLOWER")
printf '    errata OFF follower-paired = %s (want 1)\n    errata ON  follower-paired = %s (want 0)\n' \
       "$OFF_P" "$ON_P"
[ "$OFF_P" = "1" ] && ok "moffs errata OFF -> A3 store PAIRS with the EAX-using follower (UV-pairable)" \
                   || bad "moffs errata OFF: follower not paired (expected pairing)"
[ "$ON_P"  = "0" ] && ok "moffs errata ON  -> A3 store FAILS to pair with the EAX-using follower (Erratum 59)" \
                   || bad "moffs errata ON: follower still paired (expected non-pairing)"

# =============================================================================
# VERDICT
# =============================================================================
say "M6 RESULT"
for r in "${RESULTS[@]}"; do printf '    %s\n' "$r"; done
echo ""
printf '    totals: %d PASS / %d FAIL\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    echo ""
    echo "M6 GATE: FAIL -- a documented errata self-check did not match."
    exit 1
fi
echo ""
echo "M6 GATE: PASS -- all 4 documented P5 errata reproduced behind the flag and"
echo "         self-checked against the Specification-Update values (errata ON),"
echo "         with the clean behavior confirmed (errata OFF). The HARD complement"
echo "         is 'make verify' (errata OFF) staying GREEN -- run it separately."
exit 0
