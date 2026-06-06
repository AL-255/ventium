#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# run-debug-divergence.sh — "lagging capture" replay for a lockstep divergence.
#
# The deep harness streams + DELETES its traces, so a divergence verdict names
# only the first bad record n. This re-runs the SAME (fully deterministic) config,
# KEEPS the compressed golden+RTL traces, finds the divergence index N via the
# streaming comparator, and dumps the full register WINDOW [N-W, N+W] from BOTH
# sides side-by-side, plus the disassembly of the divergent PC(s) and the syscall
# context near N. The records BEFORE N are the last KNOWN-GOOD state — exactly the
# "save the state right before the divergence and debug from there" handoff.
#
# (This is the deterministic-replay realization of the dual-run/lagging idea: one
# run finds the error; this windowed re-capture freezes the pre-divergence state.
# For genuine CPU bugs, diff the window to see which instruction first goes wrong.)
#
#   bash verif/bench/run-debug-divergence.sh <bench> <max_insn> <port> [stdin] [-- argv...]
#     (same args as run-deep-lockstep.sh; WINDOW=<n> env sets the half-window, def 12)
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/ventium-refs/07-p5-emulation-harness"
QEMU="$H/build/qemu/build/qemu-i386"; BINDIR="$H/benchmarks/bin"
GEN="$REPO/verif/qemu-trace/gen_trace.py"; CMP="$REPO/verif/diff/compare_stream.py"
TB="$REPO/verif/tb/obj_dir/tb_ventium"; ZSTD="$(command -v zstd)"
PY=/usr/bin/python3; command -v "$PY" >/dev/null || PY="$(command -v python3)"
W="${WINDOW:-12}"

[[ $# -ge 3 ]] || { echo "usage: $0 <bench> <max_insn> <port> [stdin] [-- argv...]"; exit 2; }
BENCH="$1"; N="$2"; PORT="$3"; shift 3
STDIN_STR="-"; [[ $# -ge 1 && "$1" != "--" ]] && { STDIN_STR="$1"; shift; }
GUEST_ARGS=(); [[ $# -ge 1 && "$1" == "--" ]] && { shift; GUEST_ARGS=("$@"); }
if [[ "$BENCH" == "quake" ]]; then ELF="$H/quake/bin/tyr-quake-p5"; TAG="quake"
  [[ ${#GUEST_ARGS[@]} -eq 0 ]] && GUEST_ARGS=(-basedir "$H/quake" -noconinput -nosound -mem 32)
elif [[ -x "$BENCH" ]]; then ELF="$BENCH"; TAG="$(basename "$BENCH")"
elif [[ -x "$BINDIR/$BENCH" ]]; then ELF="$BINDIR/$BENCH"; TAG="$BENCH"
else echo "ERROR: bench '$BENCH' not found"; exit 2; fi
OUT="$REPO/build/debug/$TAG.$$"; mkdir -p "$OUT"
GZ="$OUT/golden.vtrace.zst"; RZ="$OUT/rtl.vtrace.zst"; SC="$OUT/syscalls.txt"; IMG="$OUT/image.json"

echo "== re-run (deterministic) keeping compressed traces: $TAG N=$N =="
GA=(--qemu "$QEMU" --syscall-proxy --elf "$ELF" --out /dev/stdout --image-out "$IMG"
    --max-insn "$N" --seed 1234 --cpu pentium --port "$PORT" --x87)
[[ ${#GUEST_ARGS[@]} -gt 0 ]] && GA+=(--args "${GUEST_ARGS[@]}")
if [[ "$STDIN_STR" == "-" ]]; then "$PY" "$GEN" "${GA[@]}" 2>"$OUT/p.log" | "$ZSTD" -q -T4 -3 -o "$GZ" -f
else printf '%b' "$STDIN_STR" | "$PY" "$GEN" "${GA[@]}" 2>"$OUT/p.log" | "$ZSTD" -q -T4 -3 -o "$GZ" -f; fi
"$ZSTD" -dc "$GZ" | awk 'NR==1{print;next}{pr=0;if(wn){print;wn=0;pr=1}if($0~/"sys_call":\{/){if(!pr)print;wn=1}}' > "$SC"
"$TB" --out >("$ZSTD" -q -T4 -3 -o "$RZ" -f) --quake-image "$IMG" --lockstep "$SC" --max-insn "$N" --x87 >"$OUT/tb.log" 2>&1

echo "== locate the divergence index N =="
DN="$("$PY" "$CMP" <("$ZSTD" -dc "$GZ") <("$ZSTD" -dc "$RZ") --x87 2>&1 | grep -oE 'n=[0-9]+' | head -1 | cut -d= -f2)"
if [[ -z "$DN" ]]; then echo "NO DIVERGENCE FOUND (config is EQUIVALENT over $N insns)"; rm -rf "$OUT"; exit 0; fi
LO=$(( DN > W ? DN - W : 0 )); HI=$(( DN + W ))
echo "   divergence at n=$DN ; window [$LO, $HI]"

dump_window() { "$ZSTD" -dc "$1" | "$PY" - "$LO" "$HI" <<'PY'
import sys,json
lo,hi=int(sys.argv[1]),int(sys.argv[2])
for line in sys.stdin:
    try: r=json.loads(line)
    except: continue
    n=r.get("n")
    if n is None: continue
    if n<lo: continue
    if n>hi: break
    g=lambda k:r.get(k,"--------")
    print(f"n={n:>9} pc={g('pc')} eax={g('eax')} ebx={g('ebx')} ecx={g('ecx')} "
          f"edx={g('edx')} esi={g('esi')} edi={g('edi')} ebp={g('ebp')} esp={g('esp')} efl={g('eflags')}")
PY
}
echo "== GOLDEN (QEMU) window =="; dump_window "$GZ" | tee "$OUT/golden.window"
echo "== RTL window =="; dump_window "$RZ" | tee "$OUT/rtl.window"
echo "== side-by-side first-difference (the last good record is N-1) =="
diff <(sed 's/pc=[^ ]* //' "$OUT/golden.window") <(sed 's/pc=[^ ]* //' "$OUT/rtl.window") | head -20
echo "== disassembly around the divergent PC =="
DPC="$(grep -oE 'pc=0x[0-9a-f]+' "$OUT/rtl.window" | sed -n "$((W+1))p" | cut -d= -f2)"
[[ -n "$DPC" ]] && objdump -d "$ELF" 2>/dev/null | grep -E "$(printf '%x' $((DPC)) )" -A2 -B6 | head -20
echo "== syscalls captured (the kernel effects replayed) =="; grep -c '"sys_call":{' "$SC" 2>/dev/null
echo "(full windows + image kept in $OUT/)"
