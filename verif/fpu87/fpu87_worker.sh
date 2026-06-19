#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# =============================================================================
# fpu87_worker.sh — per-program worker for the fpu87 gate (fanned out by
# run-fpu87-gate.sh via xargs -P). For ONE generated program it:
#   1. gcc -m32 ... -> ELF ; elf2flat -> flat image
#   2. QEMU gdbstub --x87 golden trace (the reference)
#   3. (non-transcendental) RTL --x87 trace + compare.py func  [AUTHORITATIVE]
#   4. xcheck.py: QEMU golden st0 vs the independent oracle (SoftFloat/qref)
# Writes one '|'-separated result line to $WORKDIR/<name>.result and always
# exits 0 (the verdict lives in the file).
#
# Args:  <name> <dir> <gating:0|1> <trans:0|1> <max_insn> <portidx>
# Env:   CC CFLAGS_BASE QEMU GEN_TRACE ELF2FLAT ISA_VERIFY TB_BIN COMPARE
#        XCHECK PYTHON GENDIR WORKDIR PORTBASE LOAD
# =============================================================================
set -uo pipefail
NAME="$1" DIR="$2" GATING="$3" TRANS="$4" MAX="$5" PORTIDX="$6"
W="$WORKDIR"
SRC="$GENDIR/$DIR/$NAME.s"
CASES="$GENDIR/$DIR/$NAME.cases.jsonl"
ELF="$W/$NAME.elf"; FLAT="$W/$NAME.flat"
GOLD="$W/${NAME}_golden.vtrace"; RTL="$W/${NAME}_rtl.vtrace"
CMP="$W/${NAME}_cmp.txt"; XC="$W/${NAME}_xchk.json"
RES="$W/$NAME.result"

emit() {  # <rtlverd> <xchk_json_or_dash> <detail>
    printf 'FPU|%s|%s|%s|%s|%s|%s\n' "$NAME" "$GATING" "$TRANS" "$1" "$2" "$3" > "$RES"
}

if ! "$CC" $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$SRC" 2> "$W/${NAME}_build.log"; then
    emit BUILDFAIL - "gcc build failed"; exit 0
fi
if ! "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" > "$W/${NAME}_flat.log" 2>&1; then
    emit BUILDFAIL - "elf2flat failed"; exit 0
fi

# ---- QEMU golden (the reference for both the RTL diff and the oracle xcheck) -
PORT=$(( PORTBASE + PORTIDX ))
OK=0
for attempt in 1 2 3; do
    if "$PYTHON" "$GEN_TRACE" --qemu "$QEMU" --elf "$ELF" --out "$GOLD" \
            --max-insn "$MAX" --port "$PORT" --x87 > "$W/${NAME}_qemu.log" 2>&1 \
            && [ -s "$GOLD" ] && [ "$(wc -l < "$GOLD")" -ge 2 ]; then OK=1; break; fi
    PORT=$(( PORT + 1 ))
done
[ "$OK" = 1 ] || { emit GOLDFAIL - "gen_trace golden failed"; exit 0; }

# ---- oracle triangulation (QEMU golden st0 vs SoftFloat/qref expected) -------
XJSON="-"
if [ -f "$CASES" ]; then
    "$PYTHON" "$XCHECK" --golden "$GOLD" --cases "$CASES" > "$XC" 2> "$W/${NAME}_xchk.log"
    XJSON="$(tr -d ' \n' < "$XC" 2>/dev/null)"
    [ -n "$XJSON" ] || XJSON="-"
fi

# ---- RTL diff (transcendentals need +VEN_TRANSCENDENTAL tb -> skip here) ------
if [ "$TRANS" = 1 ]; then
    emit RTLSKIP "$XJSON" "transcendental: RTL delegated to verif/trsc"; exit 0
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
if ! "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$LOAD" \
        --init-esp "$INIT_ESP" --out "$RTL" --max-insn "$MAX" --x87 \
        > "$W/${NAME}_rtl.log" 2>&1; then
    emit TBFAIL "$XJSON" "tb_ventium run failed"; exit 0
fi
"$PYTHON" "$COMPARE" --mode func "$GOLD" "$RTL" > "$CMP" 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    emit PASS "$XJSON" "func-equivalent"
else
    DIV="$(grep -m1 -E '^  n=|LENGTH MISMATCH' "$CMP" 2>/dev/null | sed 's/^ *//')"
    emit FAIL "$XJSON" "compare exit $RC; ${DIV:-divergence}"
fi
exit 0
