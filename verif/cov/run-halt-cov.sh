#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/cov/run-halt-cov.sh — HALT-arm (invalid-opcode) coverage lane.
#
# The decoder's defensive `default: d_unknown` arms only fire on INVALID/deferred
# opcodes, which drive the core to S_HALT (retire 0). Each such opcode therefore
# needs its own one-instruction image (the HALT stops execution). This lane
# assembles every verif/cov/halt/*.s (a single invalid opcode at _start) and runs
# it through the coverage TB with NO golden (the core is EXPECTED to halt; there
# is nothing to differentially check), collecting the coverage.dat so the
# defensive arms light up in the combined CORE pool.
#
# Usage:  bash verif/cov/run-halt-cov.sh
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TB_DIR="$ROOT/verif/tb"; TB_BIN="$TB_DIR/obj_dir_cov/tb_ventium"
HALT="$SCRIPT_DIR/halt"; OUT="$ROOT/build/cov/halt"; DAT="$OUT/dat"
ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
PYTHON="${PYTHON:-python3}"; CC="${CC:-gcc}"
LOAD=0x08048000
say() { printf '\n=== %s ===\n' "$*"; }
info(){ printf '    %s\n' "$*"; }

[ -x "$TB_BIN" ] || { say "build coverage TB"; make -C "$TB_DIR" cov || exit 1; }
mkdir -p "$DAT"; rm -f "$DAT"/*.dat 2>/dev/null || true

RAN=0
for SRC in "$HALT"/*.s; do
    [ -f "$SRC" ] || continue
    N="$(basename "$SRC" .s)"
    ELF="$OUT/$N.elf"; FLAT="$OUT/$N.flat"
    if ! "$CC" -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext="$LOAD" \
            -o "$ELF" "$SRC" 2>"$OUT/$N.build.log"; then
        info "$N: assemble failed"; sed 's/^/      /' "$OUT/$N.build.log" | head -4; continue; fi
    "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" >/dev/null 2>&1 || { info "$N: flat failed"; continue; }
    # No golden: the core is expected to S_HALT on the invalid opcode. A short
    # quiesce cap ends the run; coverage.dat is dumped at exit regardless.
    VEN_COV_DAT="$DAT/$N.dat" "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$LOAD" \
        --init-esp 0x40c34910 --out "$OUT/$N.vtrace" --max-cycles 5000 \
        > "$OUT/$N.log" 2>&1 || true
    if [ -f "$DAT/$N.dat" ]; then RAN=$((RAN+1)); info "$N: ran (halt expected)"; fi
done

say "HALT-arm coverage: ran $RAN invalid-opcode image(s)"
ls "$DAT"/*.dat >/dev/null 2>&1 && echo "OK (dats in $DAT, merged into the CORE pool by run-all-cov.sh)" \
    || { echo "no coverage produced"; exit 1; }
