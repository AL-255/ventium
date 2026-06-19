#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/cov/run-soc-cov.sh — SoC coverage lane (CPUID/RDTSC/INVD + devices).
#
# CPUID/RDTSC/INVD are gated on soc_en, which only exists in the full SoC (the
# soc_en port lives under VEN_L1_AXI+VEN_KV260_SOC in ventium_top). The clean
# vehicle is the ventium_soc top: its core has soc_en wired internally, so the
# bare-metal -bios firmware images (psoc*) exercise CPUID, far CALL/RETF, the
# device IN/OUT paths, real-mode interrupt delivery, etc. — AND the SoC
# peripherals (ven_pic/pit/rtc/uart/...) that no other lane touches.
#
# This is a SEPARATE pool: the ventium_soc core hierarchy differs from
# ventium_top, so it does NOT merge into the combined CORE number — it is
# reported on its own (it PROVES CPUID/RDTSC are exercised + covers the SoC).
#
# Usage:  bash verif/cov/run-soc-cov.sh   (or a subset of psoc* names)
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TB_DIR="$ROOT/verif/tb"; TB_BIN="$TB_DIR/obj_dir_soc_cov/tb_soc"
SYS="$ROOT/verif/sys/tests"
OUT="$ROOT/build/cov/soc"; DAT="$OUT/dat"
PYTHON="${PYTHON:-python3}"
VERILATOR_COVERAGE="${VERILATOR_COVERAGE:-verilator_coverage}"
COV_SUM="$SCRIPT_DIR/cov_summary.py"
MAX_CYCLES="${MAX_CYCLES:-4000000}"
MAX_INSN="${MAX_INSN:-2000}"
say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }

# Default set: the soc_en-gated boot-ISA + device demonstrators.
#   psoccpuid (CPUID), psocfarcall (far CALL/RETF), psoclseg (LSS/LFS/LGS),
#   psocrmint/psocrmexc (real-mode INT/exception delivery), psocsgdt (SGDT/SIDT),
#   psocuart (16550 IN/OUT), psoc8237 (DMA IN/OUT), psocbios (SeaBIOS WBINVD),
#   psocsregmem / psoccallfmem (MOV Sreg<->mem, far CALL m16:16).
DEFAULT_TESTS="psoccpuid psocfarcall psoclseg psocrmint psocrmexc psocsgdt \
  psocsregmem psoccallfmem psocuart psoc8237 psocdev"
TESTS=("$@"); [ "${#TESTS[@]}" -eq 0 ] && read -r -a TESTS <<<"$DEFAULT_TESTS"

say "build SoC coverage TB (verif/tb make soc-cov)"
make -C "$TB_DIR" soc-cov || { echo "soc-cov build failed"; exit 1; }
[ -x "$TB_BIN" ] || { echo "tb_soc (coverage) not built: $TB_BIN"; exit 1; }
mkdir -p "$DAT"; rm -f "$DAT"/*.dat 2>/dev/null || true

declare -a RESULTS
for T in "${TESTS[@]}"; do
    say "SOC: $T"
    TDIR="$SYS/$T"
    [ -d "$TDIR" ] || { info "no dir: $TDIR"; RESULTS+=("$T NO-DIR"); continue; }
    make -C "$TDIR" >/dev/null 2>"$OUT/${T}_build.log" || { info "image build failed"; RESULTS+=("$T BUILD-FAIL"); continue; }
    IMGREL="$(grep -oP '"image":\s*"\K[^"]+' "$TDIR/manifest.json" 2>/dev/null || echo "$T.bin")"
    IMG="$TDIR/$IMGREL"
    [ -f "$IMG" ] || { info "no image: $IMG"; RESULTS+=("$T NO-IMG"); continue; }
    if VEN_COV_DAT="$DAT/${T}.dat" "$TB_BIN" --image "$IMG" \
            --out "$OUT/${T}.vtrace" --max-cycles "$MAX_CYCLES" --max-insn "$MAX_INSN" \
            > "$OUT/${T}_run.log" 2>&1; then
        R="$(grep -oE 'retired [0-9]+ instructions' "$OUT/${T}_run.log" | head -1)"
        info "ran: $R"; [ -f "$DAT/${T}.dat" ] && RESULTS+=("$T OK ($R)") || RESULTS+=("$T NO-COV")
    else
        info "run failed (see $OUT/${T}_run.log)"; tail -3 "$OUT/${T}_run.log" | sed 's/^/      /'
        RESULTS+=("$T RUN-FAIL")
    fi
done

say "MERGE + SoC COVERAGE SUMMARY (core-under-SoC + peripherals)"
DAT_FILES=$(ls "$DAT"/*.dat 2>/dev/null || true)
[ -n "$DAT_FILES" ] || { echo "no SoC coverage produced"; exit 1; }
MERGED="$OUT/merged.dat"
if command -v "$VERILATOR_COVERAGE" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    "$VERILATOR_COVERAGE" --write "$MERGED" $DAT_FILES > "$OUT/merge.log" 2>&1 || cat $DAT_FILES > "$MERGED"
else
    cat $DAT_FILES > "$MERGED"
fi
"$PYTHON" "$COV_SUM" "$MERGED" --root "$ROOT" --worst 24 \
    --out "$OUT/cov_summary.txt" --json "$OUT/cov_summary.json" | sed -n '1,8p'

say "SoC RESULTS"
for r in "${RESULTS[@]}"; do printf '    %s\n' "$r"; done
info "full per-file table: $OUT/cov_summary.txt"
echo; echo "SoC COVERAGE: done (separate pool — CPUID/RDTSC + peripherals)."
