#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/cov/run-cov.sh — Ventium Verilator code-coverage + ISA-execution gate.
#
# Method (the task): run a FULL user-mode ISA assembly suite through a
# coverage-instrumented build of the core, measure how much RTL coverage AND
# correctness is achieved, and surface every problem so the suite can iterate:
#
#   A) build the coverage TB (verif/tb `make cov`, --coverage-line+toggle) once.
#   B) DISCOVER every program from verif/tests/**/manifest.json.
#   For EACH program:
#     1) build <name>.elf from the manifest src  (gcc -m32, GNU as, no nasm)
#     2) isa_verify the ELF (pure original-Pentium ISA)
#     3) elf2flat -> <name>.flat
#     4) golden FUNC trace via QEMU gdbstub (the correctness oracle)
#     5) run the COVERAGE TB on the flat image, dumping per-test coverage.dat
#        (VEN_COV_DAT) + the RTL retire .vtrace
#     6) compare.py --mode func        -> CORRECTNESS verdict (vs QEMU)
#     7) isa_coverage.py analyze        -> executed-opcode histogram + the first
#        UNIMPLEMENTED/diverging instruction (where the RTL retire stream stops
#        short of, or departs from, the golden)
#   C) merge every coverage.dat -> verilator_coverage annotate + cov_summary
#      (per-file line/toggle %), and isa_coverage.py report (executed ISA +
#      the consolidated unimplemented-instruction list).
#
# Usage:
#   bash verif/cov/run-cov.sh                 # full suite
#   bash verif/cov/run-cov.sh t_shift t_mul   # just these programs
#   GOLDEN=0 bash verif/cov/run-cov.sh        # coverage only (skip QEMU oracle)
#   COV_DEFS="+define+VEN_UOPCACHE" bash verif/cov/run-cov.sh   # widen RTL feats
#
# Exit: 0 iff every program built+ran AND (GOLDEN=1) was func-diff-clean.
# Artifacts: build/cov/{work,dat,annotated}/, build/cov/{cov_summary,isa}.txt.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
QEMU="$REFS/build/qemu/build/qemu-i386"
ISA_VERIFY="$REFS/tools/isa_verify.py"
GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
COMPARE="$ROOT/verif/diff/compare.py"
ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
ISA_COV="$SCRIPT_DIR/isa_coverage.py"
COV_SUM="$SCRIPT_DIR/cov_summary.py"

TESTS_DIR="$ROOT/verif/tests"
# Coverage-only tests (in verif/cov/tests) intentionally diverge from the QEMU
# golden — they exercise gated/non-differential arms (e.g. FSCALE PE-flag, SNaN)
# purely for COVERAGE and are listed in KNOWN_FAIL. They live OUTSIDE verif/tests
# so `make verify` (which scans only verif/tests) is not polluted by their fails.
COV_TESTS_DIR="$ROOT/verif/cov/tests"
TB_DIR="$ROOT/verif/tb"
TB_BIN="$TB_DIR/obj_dir_cov/tb_ventium"

BUILD="$ROOT/build/cov"
WORK="$BUILD/work"
DAT="$BUILD/dat"
ANNO="$BUILD/annotated"

PYTHON="${PYTHON:-python3}"
CC="${CC:-gcc}"
GOLDEN="${GOLDEN:-1}"
# Default: the FAITHFUL default core (same RTL config `make verify` validates),
# so correctness is meaningful. The optional iterative engines (VEN_*_ITER) are
# covered by their own bit-exact gates and are NOT enabled here — wiring them in
# changes FDIV/FSQRT/idiv/BCD timing and breaks func-equivalence. Override
# COV_DEFS for a coverage-only experiment (pair with GOLDEN=0).
COV_DEFS="${COV_DEFS:-}"
COV_PORT_BASE="${COV_PORT_BASE:-27400}"
GOLDEN_RETRIES="${GOLDEN_RETRIES:-3}"
# KNOWN gaps: programs that are EXPECTED to diverge because the default core does
# not yet implement the op (documented, same as `make verify`). Listed here they
# are reported as KNOWN-FAIL and do NOT fail the gate; a NEW divergence does.
#   tx_fprem — FPREM (x87 partial remainder) unimplemented in the default build
#              (this harness pinpoints it: halts at the `fprem` opcode).
#   tx_fpspecial2 — FSCALE overflow->Inf sets the x87 PE flag in QEMU but not in
#              the core (fstat 0x3028 vs 0x3008); a minor x87 status-flag gap. The
#              test exists to cover the FSCALE OE/UE + SNaN arms (coverage).
#   tx_transc — x87 transcendentals (F2XM1/FYL2X/FSIN/.../FPATAN) are DEFERRED
#              (d_unknown -> HALT) unless built +VEN_TRANSCENDENTAL, so the
#              default-build ISA lane halts on them; it is a FLAGS-lane coverage
#              test (run there against the feature-rich build).
# (tx_fprem was here, but the FPU overhaul made FPREM default-on via the build's
#  +define+VEN_FPREM, so tx_fprem now PASSES and is a plain make-verify test.)
KNOWN_FAIL="${KNOWN_FAIL:-tx_fpspecial2 tx_transc}"
is_known_fail() { case " $KNOWN_FAIL " in *" $1 "*) return 0;; esac; return 1; }
VERILATOR_COVERAGE="${VERILATOR_COVERAGE:-verilator_coverage}"
CFLAGS_BASE="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"

say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

manifest_get() {  # <manifest> <key>
    "$PYTHON" - "$1" "$2" <<'PY'
import sys, json
m = json.load(open(sys.argv[1])); v = m.get(sys.argv[2])
sys.exit(1) if v is None else print(v)
PY
}
golden_init_esp() {  # <golden.vtrace>
    "$PYTHON" - "$1" <<'PY'
import sys, json
try:
    with open(sys.argv[1]) as f:
        f.readline(); print(json.loads(f.readline())["esp"])
except Exception:
    print("0x40c34910")
PY
}

# =============================================================================
say "coverage gate — environment sanity"
[ -f "$ELF2FLAT" ]   || die "elf2flat.py missing: $ELF2FLAT"
[ -f "$ISA_COV" ]    || die "isa_coverage.py missing: $ISA_COV"
[ -d "$TESTS_DIR" ]  || die "tests dir missing: $TESTS_DIR"
command -v "$CC" >/dev/null 2>&1 || die "C compiler not found: $CC"
if [ "$GOLDEN" = "1" ]; then
    [ -x "$QEMU" ]      || die "qemu-i386 not found (set GOLDEN=0 to skip): $QEMU"
    [ -f "$GEN_TRACE" ] || die "gen_trace.py missing: $GEN_TRACE"
    [ -f "$COMPARE" ]   || die "compare.py missing: $COMPARE"
    [ -f "$ISA_VERIFY" ] || die "isa_verify.py missing: $ISA_VERIFY"
fi
command -v "$VERILATOR_COVERAGE" >/dev/null 2>&1 \
    || info "WARNING: verilator_coverage not on PATH — will rely on cov_summary.py only"
mkdir -p "$WORK" "$DAT" "$ANNO"
rm -f "$DAT"/*.dat "$DAT"/*.isa.json 2>/dev/null || true
info "repo root : $ROOT"
info "golden    : $GOLDEN   cov_defs: $COV_DEFS"

# ---- A) build the coverage TB ----------------------------------------------
say "A) build the coverage testbench (verif/tb make cov)"
make -C "$TB_DIR" cov COV_DEFS="$COV_DEFS" || die "coverage TB build failed"
[ -x "$TB_BIN" ] || die "coverage tb_ventium not built: $TB_BIN"
info "cov TB: $TB_BIN"

# ---- B) discover programs ---------------------------------------------------
say "B) discover programs (verif/tests/**/manifest.json)"
MANIFESTS=$(find "$TESTS_DIR" "$COV_TESTS_DIR" -mindepth 2 -maxdepth 2 -name manifest.json 2>/dev/null | sort)
[ -n "$MANIFESTS" ] || die "no manifest.json under $TESTS_DIR"

# Optional positional filter: only run programs whose name matches an argument.
FILTER=("$@")
want() {
    [ "${#FILTER[@]}" -eq 0 ] && return 0
    local n; for n in "${FILTER[@]}"; do [ "$n" = "$1" ] && return 0; done
    return 1
}

declare -a NAMES VERDICTS DETAILS
ALL_OK=1; RUN_N=0

for MANIFEST in $MANIFESTS; do
    NAME="$(manifest_get "$MANIFEST" name)" || NAME="$(basename "$(dirname "$MANIFEST")")"
    want "$NAME" || continue
    PROG_DIR="$(dirname "$MANIFEST")"
    RUN_N=$((RUN_N+1))

    SRC_REL="$(manifest_get "$MANIFEST" src)"    || SRC_REL=""
    LOAD="$(manifest_get "$MANIFEST" load_addr)" || LOAD=""
    ENTRY="$(manifest_get "$MANIFEST" entry)"    || ENTRY=""
    MAX="$(manifest_get "$MANIFEST" max_insn)"   || MAX=""
    X87="$(manifest_get "$MANIFEST" x87)"        || X87="false"
    X87_FLAG=""; [ "$X87" = "True" -o "$X87" = "true" ] && X87_FLAG="--x87"

    ELF="$WORK/${NAME}.elf"; FLAT="$WORK/${NAME}.flat"
    QEMU_VT="$WORK/${NAME}_qemu.vtrace"; RTL_VT="$WORK/${NAME}_rtl.vtrace"
    CMP="$WORK/${NAME}_cmp.txt"; COVDAT="$DAT/${NAME}.dat"; ISAJSON="$DAT/${NAME}.isa.json"

    record_fail() { ALL_OK=0; NAMES+=("$NAME"); VERDICTS+=("FAIL"); DETAILS+=("$1"); }
    say "PROGRAM: $NAME  ${X87_FLAG}"

    if [ -z "$SRC_REL" ] || [ -z "$LOAD" ] || [ -z "$ENTRY" ] || [ -z "$MAX" ]; then
        record_fail "manifest incomplete"; continue; fi
    # the source always sits in the manifest's own directory, regardless of
    # whether it came from verif/tests or verif/cov/tests.
    SRC="$PROG_DIR/$(basename "$SRC_REL")"
    [ -f "$SRC" ] || { record_fail "source missing: $SRC_REL"; continue; }

    # 1) ELF
    if ! "$CC" $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$SRC" 2> "$WORK/${NAME}_build.log"; then
        sed 's/^/      /' "$WORK/${NAME}_build.log" | head -6; record_fail "gcc build failed"; continue; fi
    # 2) ISA verify (only meaningful with the harness; skip silently if absent)
    if [ "$GOLDEN" = "1" ] && ! "$PYTHON" "$ISA_VERIFY" "$ELF" > "$WORK/${NAME}_isa.log" 2>&1; then
        sed 's/^/      /' "$WORK/${NAME}_isa.log" | head -6; record_fail "isa_verify failed"; continue; fi
    # 3) flatten
    if ! "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" > "$WORK/${NAME}_flat.log" 2>&1; then
        sed 's/^/      /' "$WORK/${NAME}_flat.log" | head -6; record_fail "elf2flat failed"; continue; fi

    INIT_ESP="0x40c34910"
    if [ "$GOLDEN" = "1" ]; then
        # 4) golden
        PORT="$("$PYTHON" - "$COV_PORT_BASE" "$NAME" <<'PY'
import sys, zlib
print(int(sys.argv[1]) + (zlib.crc32(sys.argv[2].encode()) % 4000))
PY
)"
        GOLDEN_OK=0
        for attempt in $(seq 1 "$GOLDEN_RETRIES"); do
            if "$PYTHON" "$GEN_TRACE" --qemu "$QEMU" --elf "$ELF" --out "$QEMU_VT" \
                    --max-insn "$MAX" --port "$PORT" $X87_FLAG > "$WORK/${NAME}_qemu.log" 2>&1; then
                GOLDEN_OK=1; break; fi
            info "gen_trace attempt $attempt failed (port $PORT); retrying"
        done
        [ "$GOLDEN_OK" -eq 1 ] || { sed 's/^/      /' "$WORK/${NAME}_qemu.log" | head -6; record_fail "gen_trace failed"; continue; }
        INIT_ESP="$(golden_init_esp "$QEMU_VT")"
    fi

    # 5) RTL coverage run (dump per-test coverage.dat)
    if ! VEN_COV_DAT="$COVDAT" "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
            --init-esp "$INIT_ESP" --out "$RTL_VT" --max-insn "$MAX" $X87_FLAG \
            > "$WORK/${NAME}_rtl.log" 2>&1; then
        sed 's/^/      /' "$WORK/${NAME}_rtl.log" | head -6; record_fail "cov TB run failed"; continue; fi

    # 7) ISA-execution analyze (golden optional)
    GFLAG=""; [ "$GOLDEN" = "1" ] && GFLAG="--golden $QEMU_VT"
    "$PYTHON" "$ISA_COV" analyze --name "$NAME" --rtl "$RTL_VT" --flat "$FLAT" \
        --load "$LOAD" $GFLAG --out "$ISAJSON" 2>&1 | sed 's/^/    /' || true

    # 6) CORRECTNESS verdict
    if [ "$GOLDEN" = "1" ]; then
        # compare.py auto-detects x87 from the trace header (x87:true) — it has
        # no --x87 flag, so we do NOT pass X87_FLAG here (gen_trace + tb_ventium
        # DO take it, and the header they emit drives the comparator).
        "$PYTHON" "$COMPARE" --mode func "$QEMU_VT" "$RTL_VT" > "$CMP" 2>&1
        RC=$?
        NAMES+=("$NAME")
        DIV="$(grep -m1 -E '^n=|LENGTH MISMATCH' "$CMP" 2>/dev/null || true)"
        if [ "$RC" -eq 0 ]; then VERDICTS+=("PASS"); DETAILS+=("func-equivalent");
        elif is_known_fail "$NAME"; then VERDICTS+=("KNOWN"); DETAILS+=("known gap; ${DIV:-see $CMP}");
        else ALL_OK=0; VERDICTS+=("FAIL"); DETAILS+=("compare exit $RC; ${DIV:-see $CMP}"); fi
        info "$NAME: compare exit=$RC"
    else
        NAMES+=("$NAME"); VERDICTS+=("RAN"); DETAILS+=("coverage-only (no oracle)")
    fi
done

# ---- C) aggregate coverage + ISA report ------------------------------------
say "C) merge coverage + reports"
MERGED="$BUILD/merged.dat"
DAT_FILES=$(ls "$DAT"/*.dat 2>/dev/null || true)
[ -n "$DAT_FILES" ] || die "no coverage.dat produced (did any program run?)"

if command -v "$VERILATOR_COVERAGE" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    "$VERILATOR_COVERAGE" --write "$MERGED" $DAT_FILES > "$WORK/vcov_merge.log" 2>&1 \
        || info "verilator_coverage --write reported issues (see $WORK/vcov_merge.log)"
    # shellcheck disable=SC2086
    "$VERILATOR_COVERAGE" --annotate "$ANNO" --annotate-min 1 "$MERGED" \
        > "$WORK/vcov_annotate.log" 2>&1 \
        || info "verilator_coverage --annotate reported issues (see $WORK/vcov_annotate.log)"
    info "annotated source: $ANNO  (lines marked with '%' / '~' are uncovered)"
else
    # Fall back to concatenating the raw dats; cov_summary parses the union fine.
    cat $DAT_FILES > "$MERGED"
fi

say "RTL CODE COVERAGE (line + toggle)"
"$PYTHON" "$COV_SUM" "$MERGED" --root "$ROOT" --worst 25 \
    --out "$BUILD/cov_summary.txt" --json "$BUILD/cov_summary.json"

say "ISA EXECUTION COVERAGE + UNIMPLEMENTED INSTRUCTIONS"
"$PYTHON" "$ISA_COV" report --dir "$DAT" \
    --out "$BUILD/isa.txt" --json "$BUILD/isa.json"

# ---- correctness table ------------------------------------------------------
say "PER-PROGRAM RESULT"
printf '    %-18s %-6s %s\n' "PROGRAM" "RESULT" "DETAIL"
printf '    %-18s %-6s %s\n' "-------" "------" "------"
PASS_N=0; FAIL_N=0; OTHER_N=0
for ((i=0; i<${#NAMES[@]}; i++)); do
    printf '    %-18s %-6s %s\n' "${NAMES[$i]}" "${VERDICTS[$i]}" "${DETAILS[$i]}"
    case "${VERDICTS[$i]}" in
        PASS) PASS_N=$((PASS_N+1));; FAIL) FAIL_N=$((FAIL_N+1));; *) OTHER_N=$((OTHER_N+1));;
    esac
done
echo ""
info "ran $RUN_N program(s): $PASS_N PASS / $FAIL_N FAIL / $OTHER_N other"
info "reports: $BUILD/cov_summary.txt  $BUILD/isa.txt"

if [ "$GOLDEN" = "1" ] && [ "$ALL_OK" -ne 1 ]; then
    echo ""; echo "COVERAGE GATE: FAIL — at least one program diverged (see ISA report)."; exit 1
fi
echo ""; echo "COVERAGE GATE: done (exit 0)."; exit 0
