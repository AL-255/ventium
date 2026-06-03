#!/usr/bin/env bash
# =============================================================================
# verif/run-m2.sh — Ventium M2 differential gate (docs/m2-isa-spec.md "the gate").
#
# M2 extends the M1 single-issue integer core to USER-MODE INTEGER ISA
# COMPLETENESS. The gate is FUNCTIONAL: for every test program (the M0/M1
# baseline + the new M2 corpus) the core's architectural-state trace must be
# diff-clean vs QEMU user-mode (verif/diff/compare.py --mode func exits 0, no
# length mismatch). EFLAGS undefined bits are masked per program/mnemonic by
# the comparator (verif/diff/tracefmt.py::EFLAGS_UNDEFINED).
#
# Pipeline, per program (docs/m2-isa-spec.md "Verification"):
#   A) build the RTL testbench (verif/tb against rtl/) -> obj_dir/tb_ventium
#   B) DISCOVER programs from verif/tests/**/manifest.json
#   For EACH program:
#     1) build <name>.elf generically from the manifest 'src'
#        (gcc -m32 -nostdlib -static -Wl,-Ttext=<load_addr>)  [no nasm; GNU as]
#     2) isa_verify the ELF (pure original-Pentium ISA)
#     3) elf2flat -> <name>.flat
#     4) gen_trace golden vtrace via QEMU gdbstub (--max-insn from manifest)
#     5) run tb_ventium on the flat image with --init-esp = golden n=0 ESP
#     6) compare.py --mode func  (capture exit code; do NOT abort the run)
#   Collect PASS/FAIL, print a per-program table, exit 0 ONLY if all pass.
#
# Programs are DISCOVERED, so a new verif/tests/<dir>/manifest.json (e.g. the
# parallel M2 writers' programs) is automatically enrolled — and this runner
# builds each ELF itself (it does NOT depend on verif/tests/Makefile's PROGS
# list), so newly-added M2 programs get built even before the corpus Makefile
# learns about them. This is also how the core agent iterates: programs the
# core can't yet execute simply FAIL (we print the first divergence) without
# aborting the run.
#
# Artifacts: build/m2/<name>.elf, <name>.flat, <name>_qemu.vtrace,
#            <name>_rtl.vtrace, <name>_cmp.txt.
#
# Usage:  bash verif/run-m2.sh    (or: make m2)
# Exit:   0 iff EVERY program is func-diff-clean; 1 otherwise.
# =============================================================================

set -uo pipefail
# No `set -e`: we run the producer/compare pipeline for every program and
# aggregate verdicts; an errexit would abort before the per-program table is
# printed and would defeat "robust to programs that currently FAIL". We capture
# every step's status explicitly and record a FAIL verdict instead of aborting.

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
M2="$BUILD/m2"
TB_DIR="$ROOT/verif/tb"
TB_BIN="$TB_DIR/obj_dir/tb_ventium"

PYTHON="${PYTHON:-python3}"
CC="${CC:-gcc}"

# Base gdbstub TCP port for this runner. gen_trace.py defaults to 1234, which
# collides when this gate runs alongside the parallel M2 program writers (they
# spawn their own qemu-i386 -g <port> gdbstubs) — a colliding port yields a
# "Connection reset by peer" handshake failure that has nothing to do with the
# core. We give every program a DISTINCT, deterministic high port (base + a hash
# of its name) so concurrent runs don't fight, and retry the golden step a few
# times to ride out any remaining transient (another process briefly holding the
# chosen port). Override with M2_PORT_BASE if needed.
M2_PORT_BASE="${M2_PORT_BASE:-23400}"
GOLDEN_RETRIES="${GOLDEN_RETRIES:-3}"

# Toolchain flags (match verif/tests/Makefile; -Ttext is appended per program):
#   freestanding static i386, original-Pentium ISA, no build-id NOTE segment so
#   the flat image is just headers + code/data (QEMU's loader maps it cleanly).
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

# Extract the ESP the golden reports at n=0 (the loader-established init ESP).
# Mirrors run-m1.sh: QEMU's linux-user loader places the initial stack pointer
# per program; the differential gate must drive the core with the SAME init
# ESP the golden observed, so we read it from the golden's n=0 record.
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
say "M2 gate — environment sanity"
[ -x "$QEMU" ]       || die "qemu-i386 not found/executable: $QEMU"
[ -f "$GEN_TRACE" ]  || die "gen_trace.py missing: $GEN_TRACE"
[ -f "$COMPARE" ]    || die "compare.py missing: $COMPARE"
[ -f "$ELF2FLAT" ]   || die "elf2flat.py missing: $ELF2FLAT"
[ -f "$ISA_VERIFY" ] || die "isa_verify.py missing: $ISA_VERIFY"
[ -d "$TESTS_DIR" ]  || die "tests dir missing: $TESTS_DIR"
command -v "$CC" >/dev/null 2>&1 || die "C compiler not found: $CC"
info "repo root : $ROOT"
info "qemu-i386 : $QEMU"
info "build dir : $M2"
mkdir -p "$M2"

# ---- A) build the RTL testbench against the real core -----------------------
say "A) build the RTL testbench against rtl/ (verif/tb)"
make -C "$TB_DIR" || die "RTL testbench build failed"
[ -x "$TB_BIN" ] || die "tb_ventium not built: $TB_BIN"
info "tb_ventium: $TB_BIN"

# ---- B) discover programs from verif/tests/**/manifest.json -----------------
say "B) discover programs (verif/tests/**/manifest.json)"
MANIFESTS=$(find "$TESTS_DIR" -mindepth 2 -maxdepth 2 -name manifest.json | sort)
[ -n "$MANIFESTS" ] || die "no manifest.json found under $TESTS_DIR"
for m in $MANIFESTS; do info "$(manifest_get "$m" name)  ($m)"; done

# ---- per-program differential run -------------------------------------------
declare -a NAMES
declare -a VERDICTS
declare -a DETAILS
ALL_OK=1

for MANIFEST in $MANIFESTS; do
    NAME="$(manifest_get "$MANIFEST" name)"        || NAME="$(basename "$(dirname "$MANIFEST")")"
    PROG_DIR="$(dirname "$MANIFEST")"

    # 'src' is relative to the tests dir (e.g. "t_mem/t_mem.s"); resolve it.
    SRC_REL="$(manifest_get "$MANIFEST" src)"      || SRC_REL=""
    LOAD="$(manifest_get "$MANIFEST" load_addr)"   || LOAD=""
    ENTRY="$(manifest_get "$MANIFEST" entry)"      || ENTRY=""
    MAX="$(manifest_get "$MANIFEST" max_insn)"     || MAX=""

    # M2 artifacts live under build/m2 (keep the source tree clean; do not
    # collide with run-m1.sh / the tests Makefile in-tree .elf/.flat).
    ELF="$M2/${NAME}.elf"
    FLAT="$M2/${NAME}.flat"
    QEMU_VT="$M2/${NAME}_qemu.vtrace"
    RTL_VT="$M2/${NAME}_rtl.vtrace"
    CMP="$M2/${NAME}_cmp.txt"

    record_fail() {  # <detail>
        ALL_OK=0; NAMES+=("$NAME"); VERDICTS+=("FAIL"); DETAILS+=("$1")
    }

    say "PROGRAM: $NAME"

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
    info "load/entry: $LOAD / $ENTRY    max_insn: $MAX"

    # --- 1) build the ELF generically from the manifest src ---
    if ! "$CC" $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$SRC" 2> "$M2/${NAME}_build.log"; then
        info "gcc build failed (see $M2/${NAME}_build.log):"
        sed 's/^/      /' "$M2/${NAME}_build.log" | head -8
        record_fail "ELF build failed (gcc)"
        continue
    fi

    # --- 2) static ISA check: pure original-Pentium (no MMX/SSE/CMOV/...) ---
    if ! "$PYTHON" "$ISA_VERIFY" "$ELF" > "$M2/${NAME}_isa.log" 2>&1; then
        info "isa_verify rejected the ELF (see $M2/${NAME}_isa.log):"
        sed 's/^/      /' "$M2/${NAME}_isa.log" | head -8
        record_fail "isa_verify failed (non-P5 ISA)"
        continue
    fi

    # --- 3) flatten the loadable code/data into a raw blob based at LOAD ---
    if ! "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" \
            > "$M2/${NAME}_flat.log" 2>&1; then
        info "elf2flat failed (see $M2/${NAME}_flat.log):"
        sed 's/^/      /' "$M2/${NAME}_flat.log" | head -8
        record_fail "elf2flat failed"
        continue
    fi

    # --- 4) golden FUNC trace via QEMU gdbstub ---
    # Distinct, deterministic gdbstub port per program (base + name hash mod
    # 4000), so concurrent runs / the parallel writers don't collide on 1234.
    PORT="$("$PYTHON" - "$M2_PORT_BASE" "$NAME" <<'PY'
import sys, zlib
base = int(sys.argv[1]); name = sys.argv[2]
print(base + (zlib.crc32(name.encode()) % 4000))
PY
)"
    info "gdbstub port : $PORT"
    GOLDEN_OK=0
    for attempt in $(seq 1 "$GOLDEN_RETRIES"); do
        if "$PYTHON" "$GEN_TRACE" --qemu "$QEMU" --elf "$ELF" \
                --out "$QEMU_VT" --max-insn "$MAX" --port "$PORT" \
                > "$M2/${NAME}_qemu.log" 2>&1; then
            GOLDEN_OK=1; break
        fi
        info "gen_trace.py attempt $attempt/$GOLDEN_RETRIES failed (port $PORT); retrying"
    done
    if [ "$GOLDEN_OK" -ne 1 ]; then
        info "gen_trace.py failed after $GOLDEN_RETRIES attempt(s) (see $M2/${NAME}_qemu.log):"
        sed 's/^/      /' "$M2/${NAME}_qemu.log" | head -8
        record_fail "gen_trace.py failed"
        continue
    fi

    # init ESP = the loader-established value the golden reports at n=0.
    INIT_ESP="$(golden_init_esp "$QEMU_VT")"
    info "init ESP (from golden n=0) : $INIT_ESP"

    # --- 5) RTL FUNC trace via tb_ventium on the flat image ---
    if ! "$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
            --init-esp "$INIT_ESP" --out "$RTL_VT" --max-insn "$MAX" \
            > "$M2/${NAME}_rtl.log" 2>&1; then
        info "tb_ventium run failed (see $M2/${NAME}_rtl.log):"
        sed 's/^/      /' "$M2/${NAME}_rtl.log" | head -8
        record_fail "tb_ventium run failed"
        continue
    fi

    # --- 6) functional compare (the gate) — capture rc, don't abort ---
    "$PYTHON" "$COMPARE" --mode func "$QEMU_VT" "$RTL_VT" > "$CMP" 2>&1
    RC=$?
    NAMES+=("$NAME")
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
say "M2 RESULT — per-program PASS/FAIL"
printf '    %-16s %-6s %s\n' "PROGRAM" "RESULT" "DETAIL"
printf '    %-16s %-6s %s\n' "-------" "------" "------"
N=${#NAMES[@]}
PASS_N=0; FAIL_N=0
for ((i=0; i<N; i++)); do
    printf '    %-16s %-6s %s\n' "${NAMES[$i]}" "${VERDICTS[$i]}" "${DETAILS[$i]}"
    if [ "${VERDICTS[$i]}" = "PASS" ]; then PASS_N=$((PASS_N+1)); else FAIL_N=$((FAIL_N+1)); fi
done
echo ""
info "totals: $PASS_N PASS / $FAIL_N FAIL / $N total"
echo ""

if [ "$ALL_OK" -eq 1 ]; then
    echo "M2 GATE: PASS — every program is func-diff-clean vs QEMU (exit 0)."
    exit 0
else
    echo "M2 GATE: FAIL — at least one program diverged or failed to run."
    exit 1
fi
