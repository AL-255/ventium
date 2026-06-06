#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/run-m1.sh — Ventium M1 differential gate (PLAN.md §7, docs/m1-core-spec.md).
#
# The M1 milestone replaces the M0 NOP stub with a REAL single-issue in-order
# integer core. The gate is FUNCTIONAL: for every test program (the M0 smoke
# baseline + the M1 corpus) the core's architectural-state trace must be
# diff-clean vs QEMU (verif/diff/compare.py --mode func exits 0, no length
# mismatch).
#
# Pipeline, per program (docs/m1-core-spec.md "Verification"):
#   A) build the corpus (verif/tests) -> <prog>.elf + <prog>.flat
#   B) build the RTL testbench (verif/tb against rtl/) -> obj_dir/tb_ventium
#   C) golden FUNC trace via QEMU gdbstub (gen_trace.py) -> build/m1/<p>_qemu.vtrace
#   D) RTL FUNC trace via tb_ventium on <p>.flat        -> build/m1/<p>_rtl.vtrace
#   E) compare.py --mode func  (must exit 0)
#
# Programs are DISCOVERED from verif/tests/**/manifest.json — adding a new test
# directory with a manifest automatically enrolls it in the gate.
#
# ---- init ESP note (HARNESS/SPEC reconciliation) ----------------------------
# docs/m1-core-spec.md historically documented --init-esp 0x40c348d0. That value
# is STALE: QEMU's linux-user loader actually places the initial stack pointer
# for these -Ttext=0x08048000 static binaries at 0x40c34910 (the value EVERY
# golden trace reports at n=0, and the value the passing M0 smoke baseline uses).
# Driving the core with the literal 0x40c348d0 makes ALL programs (including
# smoke) diverge at n=0 on ESP, because the core faithfully latches whatever ESP
# the loader hands it. The differential gate must therefore establish the SAME
# initial ESP the golden observed. We extract it from the golden's n=0 record
# (environment-independent, and exactly the spec's intent: "the testbench,
# playing the loader, establishes the init state the core latches at reset").
# The spec default has been corrected to 0x40c34910; see docs/m1-core-spec.md.
#
# Usage:  bash verif/run-m1.sh    (or: make m1)
# Exit:   0 iff EVERY program is func-diff-clean; 1 otherwise.
# =============================================================================

set -uo pipefail
# No `set -e`: we run the comparator for every program and aggregate verdicts;
# an errexit would abort before the per-program table is printed. Build/producer
# steps are checked explicitly via die().

# ---- locate the repo root (this script lives in <root>/verif) ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- pinned paths (all absolute) --------------------------------------------
REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
QEMU="$REFS/build/qemu/build/qemu-i386"

GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
COMPARE="$ROOT/verif/diff/compare.py"
TRACEFMT_DIR="$ROOT/verif/diff"
ELF2FLAT="$ROOT/verif/tests/elf2flat.py"

TESTS_DIR="$ROOT/verif/tests"
BUILD="$ROOT/build"
M1="$BUILD/m1"
TB_BIN="$ROOT/verif/tb/obj_dir/tb_ventium"

PYTHON="${PYTHON:-python3}"
CC="${CC:-gcc}"
# Generic build flags for programs the tests Makefile doesn't pre-build (e.g.
# the x87 corpus, auto-discovered by manifest). Matches run-m2/run-m3.sh.
CFLAGS_BASE="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"

# ---- helpers ----------------------------------------------------------------
say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Read a field out of a manifest (pure python, no jq dependency).
manifest_get() {  # <manifest> <key>
    "$PYTHON" - "$1" "$2" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
print(m[sys.argv[2]])
PY
}

# Extract the ESP the golden reports at n=0 (the loader-established init ESP).
golden_init_esp() {  # <golden.vtrace>
    "$PYTHON" - "$1" <<'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        f.readline()                      # header line
        print(json.loads(f.readline())["esp"])
except Exception:
    print("0x40c34910")                   # spec default (corrected)
PY
}

# =============================================================================
say "M1 gate — environment sanity"
[ -x "$QEMU" ]      || die "qemu-i386 not found/executable: $QEMU"
[ -f "$GEN_TRACE" ] || die "gen_trace.py missing: $GEN_TRACE"
[ -f "$COMPARE" ]   || die "compare.py missing: $COMPARE"
[ -d "$TESTS_DIR" ] || die "tests dir missing: $TESTS_DIR"
info "repo root : $ROOT"
info "qemu-i386 : $QEMU"
info "build dir : $M1"
mkdir -p "$M1"

# ---- A) build the corpus ----------------------------------------------------
say "A) build the test corpus (verif/tests)"
make -C "$TESTS_DIR" || die "corpus build failed"

# ---- B) build the RTL testbench against the real core -----------------------
say "B) build the RTL testbench against rtl/ (verif/tb)"
make -C "$ROOT/verif/tb" || die "RTL testbench build failed"
[ -x "$TB_BIN" ] || die "tb_ventium not built: $TB_BIN"
info "tb_ventium: $TB_BIN"

# ---- discover programs from verif/tests/**/manifest.json --------------------
say "Discover programs (verif/tests/**/manifest.json)"
MANIFESTS=$(find "$TESTS_DIR" -mindepth 2 -maxdepth 2 -name manifest.json | sort)
[ -n "$MANIFESTS" ] || die "no manifest.json found under $TESTS_DIR"
for m in $MANIFESTS; do info "$(manifest_get "$m" name)  ($m)"; done

# ---- per-program differential run -------------------------------------------
declare -a NAMES
declare -a VERDICTS
declare -a DETAILS
ALL_OK=1

for MANIFEST in $MANIFESTS; do
    NAME="$(manifest_get "$MANIFEST" name)"
    PROG_DIR="$(dirname "$MANIFEST")"
    ELF="$PROG_DIR/$(manifest_get "$MANIFEST" elf | sed "s#^.*/##")"
    FLAT="$PROG_DIR/$(manifest_get "$MANIFEST" image | sed "s#^.*/##")"
    LOAD="$(manifest_get "$MANIFEST" load_addr)"
    ENTRY="$(manifest_get "$MANIFEST" entry)"
    MAX="$(manifest_get "$MANIFEST" max_insn)"

    QEMU_VT="$M1/${NAME}_qemu.vtrace"
    RTL_VT="$M1/${NAME}_rtl.vtrace"

    say "PROGRAM: $NAME"

    # If the tests Makefile didn't pre-build the in-tree ELF/flat (it only knows
    # a small PROGS list; the auto-discovered x87 corpus etc. is not in it),
    # build them generically from the manifest 'src' into build/m1 — exactly the
    # mechanism run-m2.sh/run-m3.sh use. The M1 gate still compares only the
    # INTEGER architectural state (no --x87), so x87 programs are exercised here
    # purely as integer streams (which they are, aside from the FPU regs M1
    # doesn't look at). A program the core can't run simply FAILs the compare.
    if [ ! -f "$ELF" ] || [ ! -f "$FLAT" ]; then
        SRC_REL="$(manifest_get "$MANIFEST" src 2>/dev/null || true)"
        SRC="$TESTS_DIR/$SRC_REL"
        if [ -n "$SRC_REL" ] && [ -f "$SRC" ]; then
            ELF="$M1/${NAME}.elf"; FLAT="$M1/${NAME}.flat"
            if ! "$CC" $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$SRC" \
                    > "$M1/${NAME}_build.log" 2>&1; then
                ALL_OK=0; NAMES+=("$NAME"); VERDICTS+=("FAIL"); DETAILS+=("ELF build failed (gcc)"); continue
            fi
            if ! "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" \
                    > "$M1/${NAME}_flat.log" 2>&1; then
                ALL_OK=0; NAMES+=("$NAME"); VERDICTS+=("FAIL"); DETAILS+=("elf2flat failed"); continue
            fi
            info "built generically from src: $SRC"
        fi
    fi
    [ -f "$ELF" ]  || { ALL_OK=0; NAMES+=("$NAME"); VERDICTS+=("FAIL"); DETAILS+=("ELF not built: $ELF"); continue; }
    [ -f "$FLAT" ] || { ALL_OK=0; NAMES+=("$NAME"); VERDICTS+=("FAIL"); DETAILS+=("flat not built: $FLAT"); continue; }

    # C) golden FUNC trace
    if ! "$PYTHON" "$GEN_TRACE" --qemu "$QEMU" --elf "$ELF" \
            --out "$QEMU_VT" --max-insn "$MAX"; then
        ALL_OK=0; NAMES+=("$NAME"); VERDICTS+=("FAIL"); DETAILS+=("gen_trace.py failed"); continue
    fi

    # init ESP = the loader-established value the golden reports at n=0.
    INIT_ESP="$(golden_init_esp "$QEMU_VT")"
    info "init ESP (from golden n=0) : $INIT_ESP"

    # D) RTL FUNC trace
    if ! "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
            --init-esp "$INIT_ESP" --out "$RTL_VT" --max-insn "$MAX"; then
        ALL_OK=0; NAMES+=("$NAME"); VERDICTS+=("FAIL"); DETAILS+=("tb_ventium run failed"); continue
    fi

    # E) functional compare (the gate)
    "$PYTHON" "$COMPARE" --mode func "$QEMU_VT" "$RTL_VT"
    RC=$?
    NAMES+=("$NAME")
    if [ "$RC" -eq 0 ]; then
        VERDICTS+=("PASS")
        DETAILS+=("func-equivalent ($(manifest_get "$MANIFEST" max_insn) insns max)")
    else
        ALL_OK=0
        VERDICTS+=("FAIL")
        if [ "$RC" -eq 2 ]; then DETAILS+=("compare exit 2 (malformed/length mismatch)");
        else DETAILS+=("compare exit 1 (divergence)"); fi
    fi
    info "$NAME: compare --mode func exit=$RC"
done

# ---- per-program PASS/FAIL table --------------------------------------------
say "M1 RESULT — per-program PASS/FAIL"
printf '    %-12s %-6s %s\n' "PROGRAM" "RESULT" "DETAIL"
printf '    %-12s %-6s %s\n' "-------" "------" "------"
N=${#NAMES[@]}
for ((i=0; i<N; i++)); do
    printf '    %-12s %-6s %s\n' "${NAMES[$i]}" "${VERDICTS[$i]}" "${DETAILS[$i]}"
done
echo ""

if [ "$ALL_OK" -eq 1 ]; then
    echo "M1 GATE: PASS — every program is func-diff-clean vs QEMU (exit 0)."
    exit 0
else
    echo "M1 GATE: FAIL — at least one program diverged or failed to run."
    exit 1
fi
