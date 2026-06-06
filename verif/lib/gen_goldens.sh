#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# verif/lib/gen_goldens.sh — PARALLEL golden-trace generator for the Ventium gates.
#
# The differential gates' dominant cost is regenerating QEMU golden traces, done
# SEQUENTIALLY today (one program at a time, ~1 of 32 cores). Each program's
# golden is independent, so we fan out across cores: ~O(N*t) -> ~O(t). Each func
# job gets a UNIQUE gdbstub port (PORTBASE+index) so concurrent qemu -g instances
# never collide; cycle jobs use the p5trace plugin (no port).
#
# Drop-in for the gen-golden step of run-mN.sh (the band/compare checks stay as-is,
# run after this produces all goldens in parallel). See the memory
# "parallelize-gate-verification" and docs/rtl-refactor-plan.md (R1).
#
# Usage:
#   gen_goldens.sh --qemu Q --gen GEN --p5trace P5 --outdir DIR \
#                  --list JOBS [--jobs J] [--portbase P]
#   JOBS file: one program per line:  NAME ELF MAXINSN MODE X87
#       MODE = func (gdbstub via GEN) | cycle (p5trace plugin)
#       X87  = 0|1  (func only; passes --x87)
# Writes DIR/NAME.vtrace and DIR/NAME.status (OK|FAIL) per program; prints a
# summary and exits 0 iff every job produced a non-empty trace.
#
# Internal: re-invokes itself with --one for each job (so xargs -P can fan out).
set -uo pipefail

# ----- single-job worker (internal) -----------------------------------------
if [ "${1:-}" = "--one" ]; then
    shift
    QEMU="$1" GEN="$2" P5="$3" OUTDIR="$4" PORTBASE="$5"
    IDX="$6" NAME="$7" ELF="$8" MAXINSN="$9" MODE="${10}" X87="${11}"
    OUT="$OUTDIR/$NAME.vtrace"; LOG="$OUTDIR/$NAME.log"; ST="$OUTDIR/$NAME.status"
    PORT=$(( PORTBASE + IDX ))
    rc=1
    if [ "$MODE" = "cycle" ]; then
        "$QEMU" -cpu pentium -plugin "$P5,out=$OUT" "$ELF" > "$LOG" 2>&1; rc=$?
    else
        x87flag=""; [ "$X87" = "1" ] && x87flag="--x87"
        python3 "$GEN" --qemu "$QEMU" --elf "$ELF" --out "$OUT" \
            --max-insn "$MAXINSN" --port "$PORT" $x87flag > "$LOG" 2>&1; rc=$?
    fi
    # success = command ok AND a non-empty trace (header + >=1 record)
    if [ "$rc" -eq 0 ] && [ -s "$OUT" ] && [ "$(wc -l < "$OUT")" -ge 2 ]; then
        echo OK > "$ST"
    else
        echo FAIL > "$ST"
    fi
    exit 0
fi

# ----- driver ----------------------------------------------------------------
QEMU="" GEN="" P5="" OUTDIR="" LIST="" JOBS="" PORTBASE=26000
while [ $# -gt 0 ]; do
    case "$1" in
        --qemu) QEMU="$2"; shift 2;;
        --gen) GEN="$2"; shift 2;;
        --p5trace) P5="$2"; shift 2;;
        --outdir) OUTDIR="$2"; shift 2;;
        --list) LIST="$2"; shift 2;;
        --jobs) JOBS="$2"; shift 2;;
        --portbase) PORTBASE="$2"; shift 2;;
        *) echo "gen_goldens: unknown arg '$1'" >&2; exit 2;;
    esac
done
[ -n "$QEMU" ] && [ -n "$OUTDIR" ] && [ -n "$LIST" ] || { echo "gen_goldens: --qemu/--outdir/--list required" >&2; exit 2; }
[ -f "$LIST" ] || { echo "gen_goldens: list not found: $LIST" >&2; exit 2; }
# default worker count = min(nproc, #jobs); leave 2 cores headroom on big boxes.
NCPU="$(nproc 2>/dev/null || echo 4)"; [ "$NCPU" -gt 3 ] && NCPU=$(( NCPU - 2 ))
NLINES="$(grep -cvE '^\s*(#|$)' "$LIST")"
[ -z "$JOBS" ] && JOBS=$(( NCPU < NLINES ? NCPU : NLINES )); [ "$JOBS" -lt 1 ] && JOBS=1
mkdir -p "$OUTDIR"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

echo "gen_goldens: $NLINES programs, $JOBS parallel workers, portbase $PORTBASE -> $OUTDIR"
# number the (non-comment) lines and fan out: each line -> '--one ... IDX NAME ELF MAX MODE X87'
grep -nvE '^\s*(#|$)' "$LIST" | sed 's/:/ /' \
  | awk -v q="$QEMU" -v g="$GEN" -v p="$P5" -v o="$OUTDIR" -v pb="$PORTBASE" \
        '{print "--one", q, g, p, o, pb, ($1-1), $2, $3, $4, $5, $6}' \
  | xargs -P "$JOBS" -L1 bash "$SELF"

# ----- aggregate -------------------------------------------------------------
ok=0; fail=0; failed=""
while read -r idx name elf max mode x87; do
    case "$name" in ""|\#*) continue;; esac
    if [ "$(cat "$OUTDIR/$name.status" 2>/dev/null)" = "OK" ]; then
        ok=$(( ok + 1 ))
    else
        fail=$(( fail + 1 )); failed="$failed $name"
    fi
done < <(grep -vE '^\s*(#|$)' "$LIST" | awk '{print NR-1, $1, $2, $3, $4, $5}')

echo "gen_goldens: $ok OK, $fail FAIL$( [ -n "$failed" ] && echo " (failed:$failed)")"
[ "$fail" -eq 0 ]
