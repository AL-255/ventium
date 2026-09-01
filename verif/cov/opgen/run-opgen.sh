#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# verif/cov/opgen/run-opgen.sh — build + differential-check the generated
# per-opcode tests (verif/cov/opgen/tests/) against the QEMU golden, dump
# coverage, and report PASS/DIVERGE/ASM-FAIL per opcode. Self-checking: a
# mis-encoded operand shows up as ASM-FAIL, a wrong result as DIVERGE — never a
# silent miss.
#
# PARALLEL: each independent opcode worker builds its ELF, spins its own
# qemu-i386 gdbstub on a name-derived port, runs the RTL TB, and diffs.  The
# default is deliberately one worker; pass JOBS=N only inside the enclosing
# bounded resource scope.
#
# Usage:  bash verif/cov/opgen/run-opgen.sh            # all generated op_*
#         bash verif/cov/opgen/run-opgen.sh op_00 ...  # subset
#         JOBS=2 ... ; GOLDEN=0 ... (coverage only, fast)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

# Opcode coverage creates an independent assembler/QEMU/RTL process tree per
# opcode.  Keep the whole fan-out behind the shared cgroup and process lock.
if [ "${VENTIUM_BUILD_SCOPE_ACTIVE:-0}" != "1" ]; then
    exec "$ROOT/tools/build_scope.sh" -- "$0" "$@"
fi
export OPGEN_ROOT="$ROOT" OPGEN_HERE="$HERE"
export QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
export GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
export COMPARE="$ROOT/verif/diff/compare.py"
export ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
export TB="$ROOT/verif/tb/obj_dir_cov/tb_ventium"
export OUT="$ROOT/build/cov/opgen" DAT="$ROOT/build/cov/opgen/dat" WORK="$ROOT/build/cov/opgen/work"
export GOLDEN="${GOLDEN:-1}" PYTHON="${PYTHON:-python3}" CC="${CC:-gcc}"
JOBS="${JOBS:-1}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: JOBS must be a positive integer" >&2; exit 2; }
say(){ printf '\n=== %s ===\n' "$*"; }

[ -x "$TB" ] || { say "build coverage TB"; make -C "$ROOT/verif/tb" cov || exit 1; }
mkdir -p "$DAT" "$WORK"; rm -f "$DAT"/*.dat "$WORK"/*.res 2>/dev/null || true

# ---- per-opcode worker (one core) ------------------------------------------
opgen_worker() {
    local MAN="$1"
    local NAME DIR SRC LOAD ENTRY MAX ELF FLAT INIT_ESP PORT
    NAME="$("$PYTHON" -c "import json,sys;print(json.load(open(sys.argv[1]))['name'])" "$MAN")"
    DIR="$(dirname "$MAN")"
    SRC="$DIR/$("$PYTHON" -c "import json,sys,os;print(os.path.basename(json.load(open(sys.argv[1]))['src']))" "$MAN")"
    read -r LOAD ENTRY MAX X87 <<<"$("$PYTHON" -c "import json,sys;m=json.load(open(sys.argv[1]));print(m['load_addr'],m['entry'],m['max_insn'],int(bool(m.get('x87'))))" "$MAN")"
    local XF=""; [ "$X87" = 1 ] && XF="--x87"
    ELF="$WORK/$NAME.elf"; FLAT="$WORK/$NAME.flat"
    if ! "$CC" -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext="$LOAD" \
            -o "$ELF" "$SRC" 2>"$WORK/$NAME.asm.log"; then
        echo "ASMFAIL $NAME $(grep -m1 Error "$WORK/$NAME.asm.log" | tr '\n' ' ')" > "$WORK/$NAME.res"; return
    fi
    "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" >/dev/null 2>&1 \
        || { echo "ASMFAIL $NAME elf2flat" > "$WORK/$NAME.res"; return; }
    INIT_ESP="0x40c34910"
    if [ "$GOLDEN" = 1 ]; then
        local base=$(( 20000 + ($(cksum <<<"$NAME" | cut -d' ' -f1) % 40000) )) ok=0 a
        for a in 0 1 2 3; do   # retry on a fresh port to ride out gdbstub bind races
            if "$PYTHON" "$GEN_TRACE" --qemu "$QEMU" --elf "$ELF" --out "$WORK/${NAME}_q.vtrace" \
                    --max-insn "$MAX" --port $(( base + a * 1009 )) $XF >"$WORK/$NAME.gold.log" 2>&1; then
                ok=1; break; fi
        done
        [ "$ok" = 1 ] || { echo "GOLDFAIL $NAME" > "$WORK/$NAME.res"; return; }
        INIT_ESP="$("$PYTHON" -c "import json,sys
try:
 f=open(sys.argv[1]);f.readline();print(json.loads(f.readline())['esp'])
except Exception:print('0x40c34910')" "$WORK/${NAME}_q.vtrace")"
    fi
    VEN_COV_DAT="$DAT/$NAME.dat" "$TB" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
        --init-esp "$INIT_ESP" --out "$WORK/${NAME}_r.vtrace" --max-insn "$MAX" $XF >"$WORK/$NAME.rtl.log" 2>&1 || true
    if [ "$GOLDEN" = 1 ]; then
        if "$PYTHON" "$COMPARE" --mode func "$WORK/${NAME}_q.vtrace" "$WORK/${NAME}_r.vtrace" >"$WORK/$NAME.cmp" 2>&1; then
            echo "PASS $NAME" > "$WORK/$NAME.res"
        else
            echo "DIVERGE $NAME $(grep -m1 -E '^ *n=|LENGTH' "$WORK/$NAME.cmp" | tr -s ' ')" > "$WORK/$NAME.res"
        fi
    else echo "PASS $NAME" > "$WORK/$NAME.res"; fi
}
export -f opgen_worker

# ---- discover + fan out across all cores -----------------------------------
FILTER=("$@")
mapfile -t MANS < <(find "$HERE/tests" -mindepth 2 -maxdepth 2 -name manifest.json | sort)
SEL=()
for m in "${MANS[@]}"; do
    n="$(basename "$(dirname "$m")")"
    if [ "${#FILTER[@]}" -eq 0 ]; then SEL+=("$m"); else
        for f in "${FILTER[@]}"; do [ "$f" = "$n" ] && SEL+=("$m"); done
    fi
done
say "OPGEN: ${#SEL[@]} opcode tests across $JOBS cores (golden=$GOLDEN)"
printf '%s\n' "${SEL[@]}" | xargs -P "$JOBS" -I{} bash -c 'opgen_worker "$@"' _ {}

# ---- CYCLE-mode coverage pass (dual-issue fast path; coverage-only) --------
# Single-issue functional runs miss the decode.sv FP fast-decode + the U/V
# fast path; a --cycle pass over the same flats lifts decode.sv to ~100%.
if [ "${CYCLE:-1}" = 1 ]; then
    say "CYCLE-mode coverage pass (fast path)"
    mkdir -p "$DAT/cyc"
    cyc_worker(){
        local FLAT="$1" NM XF
        NM="$(basename "$FLAT" .flat)"
        XF=""; grep -q '"x87": true' "$(dirname "$FLAT")/../../../verif/cov/opgen/tests/$NM/manifest.json" 2>/dev/null && XF="--x87"
        VEN_COV_DAT="$DAT/cyc/$NM.dat" timeout 30 "$TB" --image "$FLAT" --load 0x08048000 \
            --entry 0x08048000 --init-esp 0x40c34910 --cycle $XF --out /dev/null --max-insn 400 >/dev/null 2>&1 || true
    }
    export -f cyc_worker; export DAT TB
    ls "$WORK"/op_*.flat 2>/dev/null | xargs -P "$JOBS" -I{} bash -c 'cyc_worker "$@"' _ {}
fi

# ---- aggregate (KNOWN findings vs NEW failures) ----------------------------
say "OPGEN PM32/user differential result"
KNOWN="$HERE/known_diverge.txt"
is_known(){ grep -qE "^$1[[:space:]]" "$KNOWN" 2>/dev/null; }
declare -A C=([PASS]=0 [KNOWN]=0 [FAIL]=0 [ASMFAIL]=0 [GOLDFAIL]=0)
NEWFAIL=""; RESOLVED=""
for r in "$WORK"/*.res; do
    [ -f "$r" ] || continue
    read -r s n rest < "$r"
    case "$s" in
        PASS)     C[PASS]=$((C[PASS]+1))
                  # a cataloged finding that now PASSES -> RESOLVED in RTL; the
                  # catalog should promote it to must-pass (drop the entry).
                  if is_known "$n"; then RESOLVED+="$n\n"; fi;;
        ASMFAIL)  C[ASMFAIL]=$((C[ASMFAIL]+1)); NEWFAIL+="ASM   $n $rest\n";;
        GOLDFAIL) C[GOLDFAIL]=$((C[GOLDFAIL]+1)); NEWFAIL+="GOLD  $n\n";;
        DIVERGE)  if is_known "$n"; then C[KNOWN]=$((C[KNOWN]+1));
                  else C[FAIL]=$((C[FAIL]+1)); NEWFAIL+="DIVERGE $n $rest\n"; fi;;
    esac
done
NRES=$(ls "$WORK"/*.res 2>/dev/null | wc -l)
printf '  PASS=%d  KNOWN-finding=%d  NEW-FAIL=%d  ASM-FAIL=%d  GOLD-FAIL=%d   (of %d, ran %d)\n' \
    "${C[PASS]}" "${C[KNOWN]}" "${C[FAIL]}" "${C[ASMFAIL]}" "${C[GOLDFAIL]}" "${#SEL[@]}" "$NRES"
# completeness guard: missing .res files mean workers died (usually qemu gdbstub
# port/resource exhaustion under high -P) — warn instead of reporting a false-clean.
if [ "$NRES" -lt "${#SEL[@]}" ]; then
    echo "  !! INCOMPLETE: $(( ${#SEL[@]} - NRES )) tests produced no result"
    echo "  !! (likely resource contention at -P $JOBS; re-run with e.g. JOBS=8)"
fi
if [ -n "$NEWFAIL" ]; then echo "--- NEW failures (must fix) ---"; printf "$NEWFAIL" | head -40; fi
if [ -n "$RESOLVED" ]; then
    echo "--- RESOLVED findings (now PASS — remove from known_diverge.txt + regression-protect) ---"
    printf "$RESOLVED" | sort -u | sed 's/^/  /'
fi
echo "  KNOWN findings (CORE-GAP / MODE-CPL0): see $KNOWN"
echo "  coverage dats: $(ls "$DAT"/*.dat 2>/dev/null | wc -l)"
if [ "${C[FAIL]}" -eq 0 ] && [ "${C[ASMFAIL]}" -eq 0 ] && [ "$NRES" -ge "${#SEL[@]}" ]; then
    echo "OPGEN PM32/user: CLEAN (all PASS or KNOWN)"
elif [ "$NRES" -lt "${#SEL[@]}" ]; then
    echo "OPGEN PM32/user: INCOMPLETE (re-run with lower JOBS) — not a clean verdict"
else
    echo "OPGEN PM32/user: NEW FAILURES present"
fi
