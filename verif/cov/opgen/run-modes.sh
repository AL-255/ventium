#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/cov/opgen/run-modes.sh — the MODE lane: build each generated bare-metal
# mode image (verif/cov/opgen/modes/) and DIFF it, per-record, against the
# qemu-system-i386 golden (real-mode / PM-CPL0). This covers the opcodes whose
# behaviour differs by mode/privilege — exactly the ones the PM32/user lane
# routes to MODE-CPL0 (CLI/STI/POPF), plus the privileged register/system ops
# that #GP in user mode but execute at CPL0.
#
# Usage:  bash verif/cov/opgen/run-modes.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
QSYS="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
COMPARE="$ROOT/verif/diff/compare.py"
TB="$ROOT/verif/tb/obj_dir_cov/tb_ventium"
OUT="$ROOT/build/cov/opgen/modes"; DAT="$OUT/dat"
PYTHON="${PYTHON:-python3}"
say(){ printf '\n=== %s ===\n' "$*"; }
[ -x "$QSYS" ] || { echo "qemu-system-i386 missing: $QSYS"; exit 1; }
[ -x "$TB" ] || { say "build coverage TB"; make -C "$ROOT/verif/tb" cov || exit 1; }
mkdir -p "$DAT"; rm -f "$DAT"/*.dat 2>/dev/null || true

python3 "$HERE/gen_modes.py"

declare -A C=([PASS]=0 [DIVERGE]=0 [FAIL]=0)
for d in "$HERE"/modes/*/; do
    NAME="$(basename "$d")"
    say "MODE: $NAME"
    make -C "$d" >/dev/null 2>"$OUT/$NAME.build.log" || { echo "  build FAIL"; C[FAIL]=$((C[FAIL]+1)); continue; }
    IMG="$d/$NAME.bin"
    PORT=$(( 28800 + (RANDOM % 4000) ))
    # Per-test instruction budget: the long sweep streams run hundreds of insns and
    # must NOT be truncated at 120 (qemu stops on out-0xf4, so golden/RTL lengths still
    # match at their natural exit -- verified EQUIVALENT for each). Short modes keep 120.
    case "$NAME" in
        pm32_segbase|pm32_sysregs|pm32_intsweep|pm32_paging4k) MAX=4000; MCYC=40000000 ;;
        *)                                                     MAX=120;  MCYC=4000000  ;;
    esac
    if ! "$PYTHON" "$GEN_TRACE" --qemu "$QSYS" --system --image "$IMG" --image-mode bios \
            --out "$OUT/${NAME}_q.vtrace" --max-insn "$MAX" --port "$PORT" >"$OUT/$NAME.gold.log" 2>&1; then
        echo "  golden FAIL"; C[FAIL]=$((C[FAIL]+1)); continue
    fi
    VEN_COV_DAT="$DAT/$NAME.dat" "$TB" --image "$IMG" --system --out "$OUT/${NAME}_r.vtrace" \
        --max-cycles "$MCYC" --max-insn "$MAX" >"$OUT/$NAME.rtl.log" 2>&1 || true
    if "$PYTHON" "$COMPARE" --mode func "$OUT/${NAME}_q.vtrace" "$OUT/${NAME}_r.vtrace" >"$OUT/$NAME.cmp" 2>&1; then
        echo "  PASS (matches qemu-system at CPL0/real-mode)"; C[PASS]=$((C[PASS]+1))
    else
        echo "  DIVERGE: $(grep -m1 -E '^ *n=|LENGTH' "$OUT/$NAME.cmp")"; C[DIVERGE]=$((C[DIVERGE]+1))
    fi
done

say "MODE lane result (real-mode / PM-CPL0 vs qemu-system)"
printf '  PASS=%d  DIVERGE=%d  FAIL=%d\n' "${C[PASS]}" "${C[DIVERGE]}" "${C[FAIL]}"
echo "  coverage dats: $(ls "$DAT"/*.dat 2>/dev/null | wc -l)  (privileged/real-mode core paths)"
