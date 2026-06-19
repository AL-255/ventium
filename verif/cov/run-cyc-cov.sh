#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/cov/run-cyc-cov.sh — CYCLE-MODE (dual-issue) coverage lane.
#
# Single-issue functional runs (run-cov.sh) take the SLOW execution path; the
# dual-issue U/V fast path (core_fastpath.svh, the decode.sv fast FP decode, and
# the fpu_writeback FK_* fast-path arms) only runs under --cycle. This lane
# re-runs the corpus through the coverage TB in --cycle mode (no golden — it is a
# COVERAGE pass; cycle-accuracy itself is gated by `make m4`/`m5`) and dumps the
# coverage into build/cov/cyc/dat so it merges into the combined CORE pool.
#
# Usage:  bash verif/cov/run-cyc-cov.sh   (or a subset of test names)
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TB_DIR="$ROOT/verif/tb"; TB_BIN="$TB_DIR/obj_dir_cov/tb_ventium"
TESTS_DIR="$ROOT/verif/tests"; ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
OUT="$ROOT/build/cov/cyc"; DAT="$OUT/dat"; WORK="$ROOT/build/cov/work"
PYTHON="${PYTHON:-python3}"; CC="${CC:-gcc}"
CFLAGS_BASE="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"
say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }

[ -x "$TB_BIN" ] || { say "build coverage TB"; make -C "$TB_DIR" cov || exit 1; }
mkdir -p "$DAT" "$WORK"; rm -f "$DAT"/*.dat 2>/dev/null || true

manifest_get() { "$PYTHON" - "$1" "$2" <<'PY'
import sys,json; m=json.load(open(sys.argv[1])); v=m.get(sys.argv[2])
sys.exit(1) if v is None else print(v)
PY
}

FILTER=("$@")
want() { [ "${#FILTER[@]}" -eq 0 ] && return 0; local n; for n in "${FILTER[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1; }

RAN=0
for MANIFEST in $(find "$TESTS_DIR" "$ROOT/verif/cov/tests" -mindepth 2 -maxdepth 2 -name manifest.json 2>/dev/null | sort); do
    NAME="$(manifest_get "$MANIFEST" name)" || continue
    want "$NAME" || continue
    SRC_REL="$(manifest_get "$MANIFEST" src)" || continue
    LOAD="$(manifest_get "$MANIFEST" load_addr)" || continue
    ENTRY="$(manifest_get "$MANIFEST" entry)" || continue
    MAX="$(manifest_get "$MANIFEST" max_insn)" || MAX=200000
    X87="$(manifest_get "$MANIFEST" x87)" || X87="false"
    X87_FLAG=""; { [ "$X87" = "True" ] || [ "$X87" = "true" ]; } && X87_FLAG="--x87"
    FLAT="$WORK/${NAME}.flat"
    if [ ! -f "$FLAT" ]; then
        ELF="$WORK/${NAME}.elf"
        "$CC" $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$(dirname "$MANIFEST")/$(basename "$SRC_REL")" 2>/dev/null || { info "$NAME: build skip"; continue; }
        "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" >/dev/null 2>&1 || { info "$NAME: flat skip"; continue; }
    fi
    if VEN_COV_DAT="$DAT/${NAME}.dat" "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
            --init-esp 0x40c34910 --cycle $X87_FLAG --out "$OUT/${NAME}.vtrace" \
            --max-insn "$MAX" > "$OUT/${NAME}.log" 2>&1; then
        RAN=$((RAN+1))
    else
        info "$NAME: --cycle run failed (see $OUT/${NAME}.log)"
    fi
done

say "CYCLE-MODE COVERAGE: ran $RAN test(s) in --cycle"
info "per-test coverage.dat in $DAT (merged into the CORE pool by run-all-cov.sh)"
ls "$DAT"/*.dat >/dev/null 2>&1 && echo "OK" || { echo "no coverage produced"; exit 1; }
