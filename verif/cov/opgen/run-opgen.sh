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
# PARALLEL: the per-opcode workload is distributed across ALL cores (xargs -P
# $(nproc)); each worker builds its ELF, spins its OWN qemu-i386 gdbstub on a
# name-derived port, runs the RTL TB, and diffs — fully independent.
#
# Usage:  bash verif/cov/opgen/run-opgen.sh            # all generated op_*
#         bash verif/cov/opgen/run-opgen.sh op_00 ...  # subset
#         JOBS=16 ... ; GOLDEN=0 ... (coverage only, fast)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
export OPGEN_ROOT="$ROOT" OPGEN_HERE="$HERE"
export QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
export GEN_TRACE="$ROOT/verif/qemu-trace/gen_trace.py"
export COMPARE="$ROOT/verif/diff/compare.py"
export ELF2FLAT="$ROOT/verif/tests/elf2flat.py"
export TB="$ROOT/verif/tb/obj_dir_cov/tb_ventium"
export OUT="$ROOT/build/cov/opgen" DAT="$ROOT/build/cov/opgen/dat" WORK="$ROOT/build/cov/opgen/work"
export GOLDEN="${GOLDEN:-1}" PYTHON="${PYTHON:-python3}" CC="${CC:-gcc}"
JOBS="${JOBS:-$(nproc)}"
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
    read -r LOAD ENTRY MAX <<<"$("$PYTHON" -c "import json,sys;m=json.load(open(sys.argv[1]));print(m['load_addr'],m['entry'],m['max_insn'])" "$MAN")"
    ELF="$WORK/$NAME.elf"; FLAT="$WORK/$NAME.flat"
    if ! "$CC" -m32 -march=pentium -nostdlib -static -Wl,--build-id=none -Wl,-Ttext="$LOAD" \
            -o "$ELF" "$SRC" 2>"$WORK/$NAME.asm.log"; then
        echo "ASMFAIL $NAME $(grep -m1 Error "$WORK/$NAME.asm.log" | tr '\n' ' ')" > "$WORK/$NAME.res"; return
    fi
    "$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" >/dev/null 2>&1 \
        || { echo "ASMFAIL $NAME elf2flat" > "$WORK/$NAME.res"; return; }
    INIT_ESP="0x40c34910"
    if [ "$GOLDEN" = 1 ]; then
        PORT=$(( 20000 + ($(cksum <<<"$NAME" | cut -d' ' -f1) % 40000) ))
        if ! "$PYTHON" "$GEN_TRACE" --qemu "$QEMU" --elf "$ELF" --out "$WORK/${NAME}_q.vtrace" \
                --max-insn "$MAX" --port "$PORT" >"$WORK/$NAME.gold.log" 2>&1; then
            echo "GOLDFAIL $NAME" > "$WORK/$NAME.res"; return
        fi
        INIT_ESP="$("$PYTHON" -c "import json,sys
try:
 f=open(sys.argv[1]);f.readline();print(json.loads(f.readline())['esp'])
except Exception:print('0x40c34910')" "$WORK/${NAME}_q.vtrace")"
    fi
    VEN_COV_DAT="$DAT/$NAME.dat" "$TB" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
        --init-esp "$INIT_ESP" --out "$WORK/${NAME}_r.vtrace" --max-insn "$MAX" >"$WORK/$NAME.rtl.log" 2>&1 || true
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

# ---- aggregate (KNOWN findings vs NEW failures) ----------------------------
say "OPGEN PM32/user differential result"
KNOWN="$HERE/known_diverge.txt"
is_known(){ grep -qE "^$1[[:space:]]" "$KNOWN" 2>/dev/null; }
declare -A C=([PASS]=0 [KNOWN]=0 [FAIL]=0 [ASMFAIL]=0 [GOLDFAIL]=0)
NEWFAIL=""
for r in "$WORK"/*.res; do
    [ -f "$r" ] || continue
    read -r s n rest < "$r"
    case "$s" in
        PASS)     C[PASS]=$((C[PASS]+1));;
        ASMFAIL)  C[ASMFAIL]=$((C[ASMFAIL]+1)); NEWFAIL+="ASM   $n $rest\n";;
        GOLDFAIL) C[GOLDFAIL]=$((C[GOLDFAIL]+1)); NEWFAIL+="GOLD  $n\n";;
        DIVERGE)  if is_known "$n"; then C[KNOWN]=$((C[KNOWN]+1));
                  else C[FAIL]=$((C[FAIL]+1)); NEWFAIL+="DIVERGE $n $rest\n"; fi;;
    esac
done
printf '  PASS=%d  KNOWN-finding=%d  NEW-FAIL=%d  ASM-FAIL=%d  GOLD-FAIL=%d   (of %d)\n' \
    "${C[PASS]}" "${C[KNOWN]}" "${C[FAIL]}" "${C[ASMFAIL]}" "${C[GOLDFAIL]}" "${#SEL[@]}"
if [ -n "$NEWFAIL" ]; then echo "--- NEW failures (must fix) ---"; printf "$NEWFAIL" | head -40; fi
echo "  KNOWN findings (CORE-GAP / MODE-CPL0): see $KNOWN"
echo "  coverage dats: $(ls "$DAT"/*.dat 2>/dev/null | wc -l)"
[ "${C[FAIL]}" -eq 0 ] && [ "${C[ASMFAIL]}" -eq 0 ] && echo "OPGEN PM32/user: CLEAN (all PASS or KNOWN)" || echo "OPGEN PM32/user: NEW FAILURES present"
