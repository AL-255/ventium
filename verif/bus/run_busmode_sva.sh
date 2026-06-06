#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# ============================================================================
# run_busmode_sva.sh -- M5B-int gate (3): the SINGLE bus-SVA-corpus command.
#
# (Review REVIEW_Jun5.md, Recommended Next Step 2: "Promote the integrated bus
#  SVA corpus run into a single command that builds and runs assertion-enabled
#  bus_mode=1 traffic, so the current build-only `rtl-sva` target cannot be
#  misread.")
#
# WHY THIS SCRIPT EXISTS -- the gap it closes:
#   `make -C verif/tb rtl-sva` only BUILDS the SVA-assertion-enabled integrated
#   model (obj_dir_sva/tb_ventium). A green `rtl-sva` therefore proves only that
#   the assertion-enabled model COMPILES -- it does NOT run a single instruction,
#   so it can be MISREAD as "the in-system biu_p5 SVA passed." It did not run.
#   This script removes that ambiguity: it BUILDS the SVA model AND RUNS the
#   bus_mode=1 corpus through it with the assertions LIVE, so a green verdict
#   means the 19 mutation-validated biu_p5 protocol SVA actually held on real
#   core traffic (and every program is still func-equivalent vs QEMU).
#
# WHAT IT DOES (two stages):
#   [1] BUILD: `make -C verif/tb rtl-sva`  -> verif/tb/obj_dir_sva/tb_ventium.
#       That target adds Verilator `--assert` and `bind`s verif/bus/biu_p5_sva.sv
#       (the 19 biu_p5 protocol-invariant SVA, verbatim from the standalone gate)
#       into the live integrated biu_p5 instance. (We never edit that Makefile;
#       the orchestrator owns it -- we only invoke its existing target.)
#   [2] RUN:  the SAME 12-program bus_mode=1 corpus that run_busmode_corpus.sh
#       runs (gcc -> isa_verify -> elf2flat -> CACHED gdbstub golden ->
#       tb_ventium --bus-mode -> compare.py --mode func), but pointed at the
#       SVA-ENABLED binary instead of the plain obj_dir/tb_ventium. The golden
#       cache is shared with verify.sh (keyed by sha1(.s).func.x87N.maxM and
#       INDEPENDENT of bus_mode), so this reuses any already-generated golden.
#
# PASS/FAIL semantics (a program PASSES only if BOTH hold):
#   (a) NO SVA FIRED. With Verilator `--assert`, a failed concurrent assertion
#       calls vl_fatal -> prints "%Error: ...Assertion failed..." to stderr and
#       ABORTS tb_ventium with a NON-ZERO exit. So an SVA fire shows up as the
#       tb_ventium run exiting non-zero AND/OR an "Assertion failed" line in its
#       log. We treat EITHER as a hard SVA FAIL (distinct from a func divergence).
#   (b) FUNC-EQUIVALENT vs QEMU. compare.py --mode func exits 0 (same GPRs/
#       eflags/eip, and x87 st0..st7/fctrl/fstat/ftag for the FP pair) -- i.e.
#       the data still round-trips correctly through the gated bus path.
#
#   The whole gate FAILS (exit 1) if ANY program trips (a) or (b). It prints a
#   single clear BUS-SVA-OK / BUS-SVA-FAIL verdict and a matching exit code.
#
# This is still a FUNCTIONAL + PROTOCOL-SVA check only: there is NO pin-level
# cycle oracle (docs/m5b-bus-spec.md §5.3 + the run_busmode_sva.sh note in
# §5.4), so NO cycle/timing claim is made through the bus. The integrated
# biu_p5 is a PROTOCOL EXERCISER (rtl/bus/biu.sv:25-62, docs/m5b-bus-spec.md
# §5.4): the SVA confirm protocol TIMING/sequencing on real core traffic; the
# func compare confirms architectural equivalence on the independent back-side
# data path -- the two together are exactly what a green verdict claims.
#
# NOTE for the orchestrator: `make bus-sva` will be wired -> this script.
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REFS="$ROOT/ventium-refs/07-p5-emulation-harness"

PYTHON="${PYTHON:-python3}"
CC="${CC:-gcc}"
CFLAGS_BASE="${CFLAGS_BASE:--m32 -march=pentium -nostdlib -static -Wl,--build-id=none}"
QEMU="$REFS/build/qemu/build/qemu-i386"
GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
COMPARE="$ROOT/verif/diff/compare.py"
ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
ISA_VERIFY="$REFS/tools/isa_verify.py"
TESTS_DIR="$ROOT/verif/tests"
CACHE_DIR="$ROOT/build/golden-cache"
WORK="${WORK:-$ROOT/build/busmode-sva-corpus}"
PORTBASE="${PORTBASE:-47000}"

# The SVA-ENABLED integrated binary. verif/tb/Makefile's `rtl-sva` target builds
# the SAME integrated model as the default `rtl` target but adds Verilator
# `--assert` and binds verif/bus/biu_p5_sva.sv into the live biu_p5, emitting
# verif/tb/obj_dir_sva/tb_ventium. (Override with TB_SVA_BIN= if needed.)
TB_DIR="$ROOT/verif/tb"
TB_SVA_BIN="${TB_SVA_BIN:-$TB_DIR/obj_dir_sva/tb_ventium}"
MAKE="${MAKE:-make}"

# ---- stage 1: build the SVA-assertion-enabled integrated testbench ----------
echo "=== [1/2] build SVA-assertion-enabled integrated tb (make -C verif/tb rtl-sva) ==="
if ! "$MAKE" -C "$TB_DIR" rtl-sva; then
    echo "FATAL: 'make -C verif/tb rtl-sva' failed -- cannot build the SVA model" >&2
    echo "RESULT: BUS-SVA-FAIL (build)"
    exit 2
fi
[ -x "$TB_SVA_BIN" ] || { echo "FATAL: SVA tb not built ($TB_SVA_BIN)" >&2; echo "RESULT: BUS-SVA-FAIL (build)"; exit 2; }
echo "    SVA tb built: $TB_SVA_BIN"

mkdir -p "$WORK" "$CACHE_DIR"

# ---- stage 2: run the bus_mode=1 corpus through the SVA-enabled binary -------
# The gate's named subset: m1/m2 integer programs + a couple x87 (identical to
# run_busmode_corpus.sh so the SVA run covers exactly the func-checked corpus).
PROGS="smoke t_mem t_stack t_string t_mul t_loop t_callret t_rep t_rotate t_div tx_addsub tx_ldst"

manifest_for() {  # <name> -> prints "src load entry max x87"
    local n="$1" mf
    mf="$(find "$TESTS_DIR" -mindepth 2 -maxdepth 2 -name manifest.json \
          -exec grep -l "\"name\"[[:space:]]*:[[:space:]]*\"$n\"" {} \; | head -1)"
    [ -n "$mf" ] || return 1
    "$PYTHON" - "$mf" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
def g(k,d=""):
    v=m.get(k,d); return d if v is None else v
x87=m.get("x87",False)
if isinstance(x87,str): x87=x87.strip().lower() in ("1","true","yes","on")
print(g("src"), g("load_addr"), g("entry"), g("max_insn"), "1" if x87 else "0")
PY
}

# Detect an SVA fire in a tb_ventium log. Verilator's --assert vl_fatal prints
# "%Error" + "Assertion failed"; we match either marker (case-insensitive on the
# assertion text) so a fire is caught even if the process is killed by the abort.
sva_fired_in() {  # <logfile>
    grep -qiE 'Assertion failed|%Error.*[Aa]ssert' "$1" 2>/dev/null
}

echo
echo "=== [2/2] run bus_mode=1 corpus through the SVA-enabled tb ==="
PASS=0; FAIL=0; SVA_FAILS=0; idx=0
printf '%-14s %-4s %-12s %s\n' "PROGRAM" "TYPE" "RESULT" "DETAIL"
printf '%-14s %-4s %-12s %s\n' "-------" "----" "------" "------"
for NAME in $PROGS; do
    idx=$((idx+1))
    read -r SRC_REL LOAD ENTRY MAX X87 < <(manifest_for "$NAME") || {
        printf '%-14s %-4s %-12s %s\n' "$NAME" "?" "FAIL" "no manifest"; FAIL=$((FAIL+1)); continue; }
    SRC="$TESTS_DIR/$SRC_REL"
    TYPE=$([ "$X87" = "1" ] && echo x87 || echo int)
    ELF="$WORK/$NAME.elf"; FLAT="$WORK/$NAME.flat"; RTL="$WORK/${NAME}_busrtlsva.vtrace"
    X87_FLAG=""; [ "$X87" = "1" ] && X87_FLAG="--x87"

    if ! $CC $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$SRC" 2> "$WORK/$NAME.build.log"; then
        printf '%-14s %-4s %-12s %s\n' "$NAME" "$TYPE" "FAIL" "gcc build failed"; FAIL=$((FAIL+1)); continue; fi
    if ! "$PYTHON" "$ISA_VERIFY" "$ELF" > "$WORK/$NAME.isa.log" 2>&1; then
        printf '%-14s %-4s %-12s %s\n' "$NAME" "$TYPE" "FAIL" "isa_verify failed"; FAIL=$((FAIL+1)); continue; fi
    if ! "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" > "$WORK/$NAME.flat.log" 2>&1; then
        printf '%-14s %-4s %-12s %s\n' "$NAME" "$TYPE" "FAIL" "elf2flat failed"; FAIL=$((FAIL+1)); continue; fi

    # CACHED golden (shared with verify.sh; keyed by sha1(.s).func.x87N.maxM,
    # INDEPENDENT of bus_mode -- so this reuses the verify/busmode-corpus golden).
    SHA="$(sha1sum "$SRC" | cut -d' ' -f1)"
    GOLD="$CACHE_DIR/${SHA}.func.x87${X87}.max${MAX}.vtrace"
    if [ ! -s "$GOLD" ] || [ "$(wc -l < "$GOLD")" -lt 2 ]; then
        PORT=$((PORTBASE + idx))
        TMP="$CACHE_DIR/.bmsva.${SHA}.$$.tmp"
        if "$PYTHON" "$GEN_TRACE" --qemu "$QEMU" --elf "$ELF" --out "$TMP" \
                --max-insn "$MAX" --port "$PORT" $X87_FLAG > "$WORK/$NAME.qemu.log" 2>&1 \
                && [ -s "$TMP" ] && [ "$(wc -l < "$TMP")" -ge 2 ]; then
            mv -f "$TMP" "$GOLD"
        else
            rm -f "$TMP"
            printf '%-14s %-4s %-12s %s\n' "$NAME" "$TYPE" "FAIL" "golden gen failed"; FAIL=$((FAIL+1)); continue
        fi
    fi
    INIT_ESP="$("$PYTHON" - "$GOLD" <<'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        f.readline(); print(json.loads(f.readline())["esp"])
except Exception:
    print("0x40c34910")
PY
)"

    # RTL trace WITH --bus-mode, through the SVA-ENABLED binary. If a biu_p5 SVA
    # fires, Verilator's --assert vl_fatal aborts tb_ventium NON-ZERO (and logs
    # "Assertion failed"); we check the exit status AND scan the log so the fire
    # is reported as an SVA FAIL distinct from a func divergence.
    RTL_RC=0
    "$TB_SVA_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
        --init-esp "$INIT_ESP" --out "$RTL" --max-insn "$MAX" --bus-mode $X87_FLAG \
        > "$WORK/$NAME.rtl.log" 2>&1 || RTL_RC=$?

    if sva_fired_in "$WORK/$NAME.rtl.log"; then
        printf '%-14s %-4s %-12s %s\n' "$NAME" "$TYPE" "SVA-FAIL" "biu_p5 SVA fired in-system (see $WORK/$NAME.rtl.log)"
        FAIL=$((FAIL+1)); SVA_FAILS=$((SVA_FAILS+1)); continue
    fi
    if [ "$RTL_RC" -ne 0 ]; then
        # Non-zero with no recognizable assertion text: still a hard fail (the
        # SVA-enabled run did not complete -- treat conservatively as a failure).
        printf '%-14s %-4s %-12s %s\n' "$NAME" "$TYPE" "FAIL" "SVA tb run exited $RTL_RC (see $WORK/$NAME.rtl.log)"
        FAIL=$((FAIL+1)); continue
    fi

    if "$PYTHON" "$COMPARE" --mode func "$GOLD" "$RTL" > "$WORK/$NAME.cmp.txt" 2>&1; then
        printf '%-14s %-4s %-12s %s\n' "$NAME" "$TYPE" "PASS" "SVA held + func-EQUIVALENT vs QEMU ($MAX insns max)"; PASS=$((PASS+1))
    else
        printf '%-14s %-4s %-12s %s\n' "$NAME" "$TYPE" "FAIL" "func DIVERGENT (see $WORK/$NAME.cmp.txt)"; FAIL=$((FAIL+1))
    fi
done

echo
echo "bus_mode=1 SVA corpus: $PASS PASS / $FAIL FAIL / $((PASS+FAIL)) total  (SVA fires: $SVA_FAILS)"
if [ "$FAIL" -eq 0 ]; then
    echo "RESULT: BUS-SVA-OK (19 biu_p5 protocol SVA held in-system on all $PASS programs; all func-EQUIVALENT vs QEMU)"
    exit 0
else
    if [ "$SVA_FAILS" -gt 0 ]; then
        echo "RESULT: BUS-SVA-FAIL ($SVA_FAILS program(s) tripped a biu_p5 SVA; $FAIL total failure(s))"
    else
        echo "RESULT: BUS-SVA-FAIL ($FAIL functional/build failure(s); no SVA fired)"
    fi
    exit 1
fi
