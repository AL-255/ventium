#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/cov/run-cosim-cov.sh — CPUID / RDTSC / INVD coverage via --cosim.
#
# CPUID (0F A2), RDTSC (0F 31) and INVD/WBINVD (0F 08/09) are decode-gated on
# (cosim_en || soc_en). soc_en only exists in the full SoC build (ventium_soc /
# the L1AXI+KV260 ventium_top), so on the plain ventium_top coverage TB we ungate
# them with cosim_en (the unconditional --cosim port). These bare-metal -bios
# images run under `ventium_top --system --cosim`, so the K_CPUID / K_RDTSC leaf
# tables + the 0F A2/31/08/09 decode arms light up in the SAME ventium_top
# hierarchy and MERGE into the combined CORE pool.
#
#   psoccpuid  the standard CPUID boot leaf-set (K_CPUID, cosim arm)
#   covtsc     RDTSC + WBINVD + INVD (K_RDTSC + the INVD/WBINVD NOP arms)
#
# Usage:  bash verif/cov/run-cosim-cov.sh
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TB_DIR="$ROOT/verif/tb"; TB_BIN="$TB_DIR/obj_dir_cov/tb_ventium"
OUT="$ROOT/build/cov/cosim"; DAT="$OUT/dat"
PYTHON="${PYTHON:-python3}"
say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }

[ -x "$TB_BIN" ] || { say "build coverage TB"; make -C "$TB_DIR" cov || exit 1; }
mkdir -p "$DAT"; rm -f "$DAT"/*.dat 2>/dev/null || true

# name | image-path (built first via its dir's make)
IMAGES=(
  "psoccpuid|$ROOT/verif/sys/tests/psoccpuid|psoccpuid.bin"
  "covtsc|$ROOT/verif/cov/cosim/covtsc|covtsc.bin"
  "covio|$ROOT/verif/cov/cosim/covio|covio.bin"
)

RAN=0
for entry in "${IMAGES[@]}"; do
    IFS='|' read -r NAME DIR BIN <<<"$entry"
    say "COSIM: $NAME"
    make -C "$DIR" >/dev/null 2>"$OUT/${NAME}_build.log" || { info "image build failed"; continue; }
    IMG="$DIR/$BIN"
    [ -f "$IMG" ] || { info "no image: $IMG"; continue; }
    if VEN_COV_DAT="$DAT/${NAME}.dat" "$TB_BIN" --image "$IMG" --system --cosim \
            --out "$OUT/${NAME}.vtrace" --max-cycles 1000000 --max-insn 100 \
            > "$OUT/${NAME}_run.log" 2>&1; then
        info "$(grep -oE 'retired [0-9]+ instructions' "$OUT/${NAME}_run.log" | head -1)"
        [ -f "$DAT/${NAME}.dat" ] && RAN=$((RAN+1))
    else
        info "run failed (see $OUT/${NAME}_run.log)"
    fi
done

say "COSIM CPUID/RDTSC coverage: ran $RAN image(s)"
ls "$DAT"/*.dat >/dev/null 2>&1 && echo "OK (dats merge into the combined CORE pool)" \
    || { echo "no coverage produced"; exit 1; }
