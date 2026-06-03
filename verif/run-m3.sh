#!/usr/bin/env bash
# =============================================================================
# verif/run-m3.sh — Ventium M3 differential gate (docs/m3-fpu-spec.md "the gate").
#
# M3 adds the x87 FPU and verifies the x87 architectural state diff-clean vs
# QEMU user-mode. The gate is FUNCTIONAL: for every test program (the M0/M1/M2
# integer baseline + the new x87 corpus) the core's architectural-state trace
# must be diff-clean vs QEMU (verif/diff/compare.py --mode func exits 0, no
# length mismatch).
#
# This runner is an EXTENSION of run-m2.sh. The only structural addition is
# per-program x87 mode: a program's manifest.json may carry an optional
#   "x87": true
# field (default false). For x87 programs we pass --x87 to BOTH gen_trace.py
# (golden header x87:true, st0..st7/fctrl/fstat/ftag in records) AND tb_ventium
# (RTL header x87:true, same fields). compare.py then compares the x87 fields
# (it does so iff BOTH headers say x87 — integer programs keep x87:false and are
# unaffected). Everything else (ELF build, isa_verify, elf2flat, golden+RTL
# trace, init-ESP from golden n=0, per-program port, PASS/FAIL table) is
# identical to run-m2.sh.
#
# Programs are DISCOVERED from verif/tests/**/manifest.json, so the x87 corpus
# (authored by sibling agents) is auto-enrolled. Programs the core can't yet
# execute simply FAIL (we print the first divergence) without aborting the run.
# Per m3-fpu-spec.md: anything unimplemented/deferred must HALT loudly in the
# core (never silently mis-execute) — such a program shows up here as a FAIL/
# length-mismatch, not a false PASS.
#
# Artifacts: build/m3/<name>.elf, <name>.flat, <name>_qemu.vtrace,
#            <name>_rtl.vtrace, <name>_cmp.txt, plus per-step logs.
#
# Usage:  bash verif/run-m3.sh    (or: make m3)
# Exit:   0 iff EVERY program is func-diff-clean; 1 otherwise.
# =============================================================================

set -uo pipefail
# No `set -e`: we run the producer/compare pipeline for every program and
# aggregate verdicts; an errexit would abort before the per-program table is
# printed. We capture every step's status explicitly and record a FAIL verdict
# instead of aborting.

# ---- locate the repo root (this script lives in <root>/verif) ---------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- pinned paths (all absolute) --------------------------------------------
REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
QEMU="$REFS/build/qemu/build/qemu-i386"
ISA_VERIFY="$REFS/tools/isa_verify.py"

GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
COMPARE="$ROOT/verif/diff/compare.py"
ELF2FLAT="$ROOT/verif/tests/elf2flat.py"

TESTS_DIR="$ROOT/verif/tests"
BUILD="$ROOT/build"
M3="$BUILD/m3"
TB_DIR="$ROOT/verif/tb"
TB_BIN="$TB_DIR/obj_dir/tb_ventium"

PYTHON="${PYTHON:-python3}"
CC="${CC:-gcc}"

# Base gdbstub TCP port (distinct from run-m2's 23400 so the two gates can run
# concurrently without colliding on the stub port). Override with M3_PORT_BASE.
M3_PORT_BASE="${M3_PORT_BASE:-24400}"
GOLDEN_RETRIES="${GOLDEN_RETRIES:-3}"

# Toolchain flags (match run-m2.sh; -Ttext is appended per program). x87
# programs need the FPU enabled in the assembler/codegen, which -march=pentium
# already provides (the P5 has x87 on-die).
CFLAGS_BASE="-m32 -march=pentium -nostdlib -static -Wl,--build-id=none"

# ---- helpers ----------------------------------------------------------------
say()  { printf '\n=== %s ===\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Read a field out of a manifest (pure python, no jq dependency). Prints empty
# and returns nonzero if the key is absent so callers can default.
manifest_get() {  # <manifest> <key>
    "$PYTHON" - "$1" "$2" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
v = m.get(sys.argv[2])
if v is None:
    sys.exit(1)
print(v)
PY
}

# Read the optional boolean "x87" manifest field. Prints "1" if true, else "0".
# Accepts JSON true/false or the strings/ints "1"/1. Default (absent) = 0.
manifest_x87() {  # <manifest>
    "$PYTHON" - "$1" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
v = m.get("x87", False)
if isinstance(v, str):
    v = v.strip().lower() in ("1", "true", "yes", "on")
print("1" if v else "0")
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
    print("0x40c34910")                   # spec default (corrected, see run-m1.sh)
PY
}

# Print the first divergence line from a saved compare report (for FAIL detail).
first_divergence() {  # <cmp.txt>
    "$PYTHON" - "$1" <<'PY'
import sys
try:
    for line in open(sys.argv[1]):
        s = line.strip()
        if s.startswith("n=") or "LENGTH MISMATCH" in s:
            print(s)
            break
except Exception:
    pass
PY
}

# =============================================================================
say "M3 gate — environment sanity"
[ -x "$QEMU" ]       || die "qemu-i386 not found/executable: $QEMU"
[ -f "$GEN_TRACE" ]  || die "gen_trace.py missing: $GEN_TRACE"
[ -f "$COMPARE" ]    || die "compare.py missing: $COMPARE"
[ -f "$ELF2FLAT" ]   || die "elf2flat.py missing: $ELF2FLAT"
[ -f "$ISA_VERIFY" ] || die "isa_verify.py missing: $ISA_VERIFY"
[ -d "$TESTS_DIR" ]  || die "tests dir missing: $TESTS_DIR"
command -v "$CC" >/dev/null 2>&1 || die "C compiler not found: $CC"
info "repo root : $ROOT"
info "qemu-i386 : $QEMU"
info "build dir : $M3"
mkdir -p "$M3"

# ---- A) build the RTL testbench against the real core -----------------------
say "A) build the RTL testbench against rtl/ (verif/tb)"
make -C "$TB_DIR" || die "RTL testbench build failed"
[ -x "$TB_BIN" ] || die "tb_ventium not built: $TB_BIN"
info "tb_ventium: $TB_BIN"

# ---- B) discover programs from verif/tests/**/manifest.json -----------------
say "B) discover programs (verif/tests/**/manifest.json)"
MANIFESTS=$(find "$TESTS_DIR" -mindepth 2 -maxdepth 2 -name manifest.json | sort)
[ -n "$MANIFESTS" ] || die "no manifest.json found under $TESTS_DIR"
for m in $MANIFESTS; do
    if [ "$(manifest_x87 "$m")" = "1" ]; then x87tag="[x87]"; else x87tag=""; fi
    info "$(manifest_get "$m" name)  ($m) $x87tag"
done

# ---- per-program differential run -------------------------------------------
declare -a NAMES
declare -a VERDICTS
declare -a DETAILS
declare -a MODES
ALL_OK=1

for MANIFEST in $MANIFESTS; do
    NAME="$(manifest_get "$MANIFEST" name)"        || NAME="$(basename "$(dirname "$MANIFEST")")"
    PROG_DIR="$(dirname "$MANIFEST")"

    # 'src' is relative to the tests dir (e.g. "t_mem/t_mem.s"); resolve it.
    SRC_REL="$(manifest_get "$MANIFEST" src)"      || SRC_REL=""
    LOAD="$(manifest_get "$MANIFEST" load_addr)"   || LOAD=""
    ENTRY="$(manifest_get "$MANIFEST" entry)"      || ENTRY=""
    MAX="$(manifest_get "$MANIFEST" max_insn)"     || MAX=""
    X87="$(manifest_x87 "$MANIFEST")"              || X87="0"

    # M3 artifacts live under build/m3 (keep the source tree clean).
    ELF="$M3/${NAME}.elf"
    FLAT="$M3/${NAME}.flat"
    QEMU_VT="$M3/${NAME}_qemu.vtrace"
    RTL_VT="$M3/${NAME}_rtl.vtrace"
    CMP="$M3/${NAME}_cmp.txt"

    if [ "$X87" = "1" ]; then MODE="x87"; else MODE="int"; fi

    record_fail() {  # <detail>
        ALL_OK=0; NAMES+=("$NAME"); VERDICTS+=("FAIL"); DETAILS+=("$1"); MODES+=("$MODE")
    }

    say "PROGRAM: $NAME  (mode=$MODE)"

    # --- manifest field sanity ---
    if [ -z "$SRC_REL" ] || [ -z "$LOAD" ] || [ -z "$ENTRY" ] || [ -z "$MAX" ]; then
        info "manifest missing required field (src/load_addr/entry/max_insn)"
        record_fail "manifest incomplete (need src/load_addr/entry/max_insn)"
        continue
    fi
    SRC="$TESTS_DIR/$SRC_REL"
    if [ ! -f "$SRC" ]; then
        info "source not found: $SRC"
        record_fail "source missing: $SRC_REL"
        continue
    fi
    info "src      : $SRC"
    info "load/entry: $LOAD / $ENTRY    max_insn: $MAX    x87: $X87"

    # --- 1) build the ELF generically from the manifest src ---
    if ! "$CC" $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$SRC" 2> "$M3/${NAME}_build.log"; then
        info "gcc build failed (see $M3/${NAME}_build.log):"
        sed 's/^/      /' "$M3/${NAME}_build.log" | head -8
        record_fail "ELF build failed (gcc)"
        continue
    fi

    # --- 2) static ISA check: pure original-Pentium (x87 is part of P5) ---
    if ! "$PYTHON" "$ISA_VERIFY" "$ELF" > "$M3/${NAME}_isa.log" 2>&1; then
        info "isa_verify rejected the ELF (see $M3/${NAME}_isa.log):"
        sed 's/^/      /' "$M3/${NAME}_isa.log" | head -8
        record_fail "isa_verify failed (non-P5 ISA)"
        continue
    fi

    # --- 3) flatten the loadable code/data into a raw blob based at LOAD ---
    if ! "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" \
            > "$M3/${NAME}_flat.log" 2>&1; then
        info "elf2flat failed (see $M3/${NAME}_flat.log):"
        sed 's/^/      /' "$M3/${NAME}_flat.log" | head -8
        record_fail "elf2flat failed"
        continue
    fi

    # --- 4) golden FUNC trace via QEMU gdbstub (pass --x87 for x87 programs) ---
    PORT="$("$PYTHON" - "$M3_PORT_BASE" "$NAME" <<'PY'
import sys, zlib
base = int(sys.argv[1]); name = sys.argv[2]
print(base + (zlib.crc32(name.encode()) % 4000))
PY
)"
    info "gdbstub port : $PORT"
    X87_FLAG=""
    [ "$X87" = "1" ] && X87_FLAG="--x87"
    GOLDEN_OK=0
    for attempt in $(seq 1 "$GOLDEN_RETRIES"); do
        if "$PYTHON" "$GEN_TRACE" --qemu "$QEMU" --elf "$ELF" \
                --out "$QEMU_VT" --max-insn "$MAX" --port "$PORT" $X87_FLAG \
                > "$M3/${NAME}_qemu.log" 2>&1; then
            GOLDEN_OK=1; break
        fi
        info "gen_trace.py attempt $attempt/$GOLDEN_RETRIES failed (port $PORT); retrying"
    done
    if [ "$GOLDEN_OK" -ne 1 ]; then
        info "gen_trace.py failed after $GOLDEN_RETRIES attempt(s) (see $M3/${NAME}_qemu.log):"
        sed 's/^/      /' "$M3/${NAME}_qemu.log" | head -8
        record_fail "gen_trace.py failed"
        continue
    fi

    # init ESP = the loader-established value the golden reports at n=0.
    INIT_ESP="$(golden_init_esp "$QEMU_VT")"
    info "init ESP (from golden n=0) : $INIT_ESP"

    # --- 5) RTL FUNC trace via tb_ventium (pass --x87 for x87 programs) ---
    if ! "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
            --init-esp "$INIT_ESP" --out "$RTL_VT" --max-insn "$MAX" $X87_FLAG \
            > "$M3/${NAME}_rtl.log" 2>&1; then
        info "tb_ventium run failed (see $M3/${NAME}_rtl.log):"
        sed 's/^/      /' "$M3/${NAME}_rtl.log" | head -8
        record_fail "tb_ventium run failed"
        continue
    fi

    # --- 6) functional compare (the gate) — capture rc, don't abort ---
    "$PYTHON" "$COMPARE" --mode func "$QEMU_VT" "$RTL_VT" > "$CMP" 2>&1
    RC=$?
    NAMES+=("$NAME")
    MODES+=("$MODE")
    if [ "$RC" -eq 0 ]; then
        VERDICTS+=("PASS")
        DETAILS+=("func-equivalent ($MAX insns max)")
    else
        ALL_OK=0
        VERDICTS+=("FAIL")
        DIV="$(first_divergence "$CMP")"
        if [ "$RC" -eq 2 ]; then
            DETAILS+=("compare exit 2 (malformed/length); ${DIV:-see $CMP}")
        else
            DETAILS+=("compare exit 1; ${DIV:-divergence — see $CMP}")
        fi
    fi
    info "$NAME: compare --mode func exit=$RC"
done

# ---- per-program PASS/FAIL table --------------------------------------------
say "M3 RESULT — per-program PASS/FAIL"
printf '    %-16s %-5s %-6s %s\n' "PROGRAM" "MODE" "RESULT" "DETAIL"
printf '    %-16s %-5s %-6s %s\n' "-------" "----" "------" "------"
N=${#NAMES[@]}
PASS_N=0; FAIL_N=0
for ((i=0; i<N; i++)); do
    printf '    %-16s %-5s %-6s %s\n' \
        "${NAMES[$i]}" "${MODES[$i]}" "${VERDICTS[$i]}" "${DETAILS[$i]}"
    if [ "${VERDICTS[$i]}" = "PASS" ]; then PASS_N=$((PASS_N+1)); else FAIL_N=$((FAIL_N+1)); fi
done
echo ""
info "totals: $PASS_N PASS / $FAIL_N FAIL / $N total"
echo ""

if [ "$ALL_OK" -eq 1 ]; then
    echo "M3 GATE: PASS — every program is func-diff-clean vs QEMU (exit 0)."
    exit 0
else
    echo "M3 GATE: FAIL — at least one program diverged or failed to run."
    exit 1
fi
