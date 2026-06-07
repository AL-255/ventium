#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# run-quake-fb.sh — FREE-RUN Quake on the RTL and CAPTURE THE FRAMEBUFFER.
#
# The Ventium RTL executes the TyrQuake P5 build to its demo render loop via the
# M14 free-run emulator (real file I/O for pak0.pak; int-0x80 emulated). Quake's
# vid_p5fb backend streams each rendered frame (P5Q1: palette[768]+pixels[64000])
# by write()ing to $P5Q_VIDEO; the emulator CAPTURES that stream, and we convert
# it to PNGs — so you can literally SEE the demo the RTL rendered.
#
#   bash verif/bench/run-quake-fb.sh [MAX_INSN] [EVERY]
#     MAX_INSN  free-run instruction budget (default 120000000; the first demo
#               frames land after Quake loads the pak + spawns the demo).
#     EVERY     keep every Nth frame as a PNG (default 1).
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$REPO/ventium-refs/07-p5-emulation-harness"
QEMU="$H/build/qemu/build/qemu-i386"; ELF="$H/quake/bin/tyr-quake-p5"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
TB="$REPO/verif/tb/obj_dir_emu/tb_ventium"; [[ -x "$TB" ]] || TB="$REPO/verif/tb/obj_dir/tb_ventium"
PY=/usr/bin/python3; command -v "$PY" >/dev/null || PY="$(command -v python3)"
N="${1:-120000000}"; EVERY="${2:-1}"
VIDP="/p5q_video_capture"          # sentinel $P5Q_VIDEO path (matched, never opened)
OUT="$REPO/build/quake-fb"; mkdir -p "$OUT"; IMG="$OUT/image.json"
# No "+map start": loading a map precaches every model and converts each skin via
# qpal_24to8 (per-pixel 256-entry nearest-colour search) = billions of insns at
# free-run speed. Without a map, Quake renders its CONSOLE/attract screen first —
# a real RTL-rendered frame, reachable far sooner. (Set MAP=start to force a map.)
GA=(-basedir "$H/quake" -noconinput -nosound -mem 32)
[[ -n "${MAP:-}" ]] && GA+=(+map "$MAP")

[[ -x "$ELF" && -f "$H/quake/id1/pak0.pak" ]] || { echo "missing quake guest/data"; exit 1; }

echo "== 1. capture initial image (P5Q_VIDEO=$VIDP in the guest env) =="
P5Q_VIDEO="$VIDP" "$PY" "$GEN" --qemu "$QEMU" --syscall-proxy --elf "$ELF" \
   --out /dev/null --image-out "$IMG" --max-insn 1 --seed 1234 --cpu pentium \
   --port 55300 --x87 --args "${GA[@]}" 2>"$OUT/img.log" \
   || { echo "image capture FAILED"; tail "$OUT/img.log"; exit 1; }
BRK="$("$PY" - "$IMG" <<'PY'
import json,sys
m=json.load(open(sys.argv[1])); end=0
for r in m.get("regions",[]):
    v=int(str(r["vaddr"]),0)
    if v>=0x40000000: continue
    end=max(end, v+(len(r["hex"])//2 if "hex" in r else int(r.get("len",0))))
print(hex((end+0xfff)&~0xfff))
PY
)"
echo "   image ok; brk_base=$BRK"

echo "== 2. RTL free-run Quake (emulate syscalls + capture frame stream), N=$N =="
# --quiesce high: free-run ends at exit_group, not quiescence; a multi-cycle SRT
# divide legitimately exceeds the default 64-clock no-retire window. (If the core
# stalls >100k clocks here, THAT is a genuine hang bug, not a false trip.)
"$TB" --out /dev/null --quake-image "$IMG" --emulate-syscalls --user-stdin /dev/null \
      --brk-base "$BRK" --max-insn "$N" --max-cycles $(( N * 16 )) --quiesce 100000 --x87 \
      --video-path "$VIDP" --video-out "$OUT/frames.p5q" \
      --user-stdout "$OUT/quake.out" 2>&1 | grep -iE 'FREE-RUN|stop:|video stream|UNIMPL' | head

echo "== 3. convert captured frames -> PNG =="
if [[ -s "$OUT/frames.p5q" ]]; then
  "$PY" "$REPO/verif/bench/p5q_to_png.py" "$OUT/frames.p5q" "$OUT/png" --every "$EVERY"
  echo "   PNGs in $OUT/png/"
else
  echo "   NO frames captured (Quake did not reach a VID_Update within $N insns)."
  echo "   guest stdout tail:"; tail -8 "$OUT/quake.out" 2>/dev/null | sed 's/^/     /'
fi
