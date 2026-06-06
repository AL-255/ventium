#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# M5B-int gate (2): bus_mode=1 FUNCTIONAL corpus.
#
# Replicates the verify.sh/verify_worker.sh func pipeline (gcc -> isa_verify ->
# elf2flat -> CACHED gdbstub golden -> tb_ventium -> compare.py --mode func) but
# adds --bus-mode so the core memory is routed through the biu subsystem (the
# real biu_p5 pin protocol runs in parallel). The golden depends ONLY on the .s
# source (+ mode/x87/max), NOT on bus_mode, so we reuse the verify golden cache.
#
# A program PASSES if compare.py --mode func exits 0 (same GPRs/eflags/eip, and
# x87 st0..st7/fctrl/fstat/ftag for the FP pair) — i.e. architecturally
# EQUIVALENT vs QEMU with the data flowing through the real pin protocol.
#
# This is a FUNCTIONAL check only — there is NO pin cycle oracle (m5b-bus-spec
# §5.3), so no cycle/timing claim is made through the bus.
set -u
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
TB_BIN="${TB_BIN:-$ROOT/verif/tb/obj_dir/tb_ventium}"
TESTS_DIR="$ROOT/verif/tests"
CACHE_DIR="$ROOT/build/golden-cache"
WORK="${WORK:-$ROOT/build/busmode-corpus}"
PORTBASE="${PORTBASE:-46000}"

[ -x "$TB_BIN" ] || { echo "FATAL: tb_ventium not built ($TB_BIN)"; exit 2; }
mkdir -p "$WORK" "$CACHE_DIR"

# The gate's named subset: m1/m2 integer programs + a couple x87.
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

PASS=0; FAIL=0; idx=0
printf '%-14s %-4s %-10s %s\n' "PROGRAM" "TYPE" "RESULT" "DETAIL"
printf '%-14s %-4s %-10s %s\n' "-------" "----" "------" "------"
for NAME in $PROGS; do
    idx=$((idx+1))
    read -r SRC_REL LOAD ENTRY MAX X87 < <(manifest_for "$NAME") || {
        printf '%-14s %-4s %-10s %s\n' "$NAME" "?" "FAIL" "no manifest"; FAIL=$((FAIL+1)); continue; }
    SRC="$TESTS_DIR/$SRC_REL"
    TYPE=$([ "$X87" = "1" ] && echo x87 || echo int)
    ELF="$WORK/$NAME.elf"; FLAT="$WORK/$NAME.flat"; RTL="$WORK/${NAME}_busrtl.vtrace"
    X87_FLAG=""; [ "$X87" = "1" ] && X87_FLAG="--x87"

    if ! $CC $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$SRC" 2> "$WORK/$NAME.build.log"; then
        printf '%-14s %-4s %-10s %s\n' "$NAME" "$TYPE" "FAIL" "gcc build failed"; FAIL=$((FAIL+1)); continue; fi
    if ! "$PYTHON" "$ISA_VERIFY" "$ELF" > "$WORK/$NAME.isa.log" 2>&1; then
        printf '%-14s %-4s %-10s %s\n' "$NAME" "$TYPE" "FAIL" "isa_verify failed"; FAIL=$((FAIL+1)); continue; fi
    if ! "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" > "$WORK/$NAME.flat.log" 2>&1; then
        printf '%-14s %-4s %-10s %s\n' "$NAME" "$TYPE" "FAIL" "elf2flat failed"; FAIL=$((FAIL+1)); continue; fi

    # CACHED golden (shared with verify.sh; keyed by sha1(.s).func.x87N.maxM).
    SHA="$(sha1sum "$SRC" | cut -d' ' -f1)"
    GOLD="$CACHE_DIR/${SHA}.func.x87${X87}.max${MAX}.vtrace"
    if [ ! -s "$GOLD" ] || [ "$(wc -l < "$GOLD")" -lt 2 ]; then
        PORT=$((PORTBASE + idx))
        TMP="$CACHE_DIR/.bm.${SHA}.$$.tmp"
        if "$PYTHON" "$GEN_TRACE" --qemu "$QEMU" --elf "$ELF" --out "$TMP" \
                --max-insn "$MAX" --port "$PORT" $X87_FLAG > "$WORK/$NAME.qemu.log" 2>&1 \
                && [ -s "$TMP" ] && [ "$(wc -l < "$TMP")" -ge 2 ]; then
            mv -f "$TMP" "$GOLD"
        else
            rm -f "$TMP"
            printf '%-14s %-4s %-10s %s\n' "$NAME" "$TYPE" "FAIL" "golden gen failed"; FAIL=$((FAIL+1)); continue
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

    # RTL trace WITH --bus-mode (the only difference vs the verify func path).
    if ! "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
            --init-esp "$INIT_ESP" --out "$RTL" --max-insn "$MAX" --bus-mode $X87_FLAG \
            > "$WORK/$NAME.rtl.log" 2>&1; then
        printf '%-14s %-4s %-10s %s\n' "$NAME" "$TYPE" "FAIL" "tb_ventium --bus-mode run failed"; FAIL=$((FAIL+1)); continue; fi

    if "$PYTHON" "$COMPARE" --mode func "$GOLD" "$RTL" > "$WORK/$NAME.cmp.txt" 2>&1; then
        printf '%-14s %-4s %-10s %s\n' "$NAME" "$TYPE" "PASS" "func-EQUIVALENT vs QEMU ($MAX insns max)"; PASS=$((PASS+1))
    else
        printf '%-14s %-4s %-10s %s\n' "$NAME" "$TYPE" "FAIL" "func DIVERGENT (see $WORK/$NAME.cmp.txt)"; FAIL=$((FAIL+1))
    fi
done

echo
echo "bus_mode=1 func corpus: $PASS PASS / $FAIL FAIL / $((PASS+FAIL)) total"
[ "$FAIL" -eq 0 ] && { echo "RESULT: ALL EQUIVALENT (bus_mode=1)"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
