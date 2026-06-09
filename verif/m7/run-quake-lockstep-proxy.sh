#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# verif/m7/run-quake-lockstep-proxy.sh — F4 proof that the GATED int-0x80 stall
# (+VEN_PS_PROXY, S_SYSCALL_WAIT) reproduces the zero-latency proxy on a REAL Quake
# int-0x80 stream. Reuses run-quake-lockstep's QEMU golden, but builds `make proxy`
# (the core parks in S_SYSCALL_WAIT and commits only on syscall_resp_valid, which
# tb_main asserts after an 8-clock service latency). The stalled RTL trace must be
# bit-exact vs the SAME golden the zero-latency build matches -> the stall is
# architecturally equivalent, just later.
#   bash verif/m7/run-quake-lockstep-proxy.sh [N_INSNS] [PORT]
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$REPO/ventium-refs/07-p5-emulation-harness"
QEMU="$HARNESS/build/qemu/build/qemu-i386"
QBIN="$HARNESS/quake/bin/tyr-quake-p5"
QDATA="$HARNESS/quake"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
OUT="$REPO/build/m7"; mkdir -p "$OUT"
N="${1:-8000}"; PORT="${2:-52070}"
GOLDEN="$OUT/quake-startup-proxy.vtrace"; IMAGE="$OUT/quake-initial-image-proxy.json"
RTL="$OUT/quake-rtl-proxy.vtrace"
PY=/usr/bin/python3; command -v "$PY" >/dev/null || PY="$(command -v python3)"

[[ -x "$QBIN" ]] || { echo "missing guest: $QBIN"; exit 1; }
[[ -f "$QDATA/id1/pak0.pak" ]] || { echo "missing shareware data"; exit 1; }

echo "== 1. producer: golden + initial image ($N insns) =="
"$PY" "$GEN" --qemu "$QEMU" --syscall-proxy --elf "$QBIN" \
    --out "$GOLDEN" --image-out "$IMAGE" --max-insn "$N" --seed 1234 \
    --cpu pentium --port "$PORT" \
    --args -basedir "$QDATA" -noconinput -nosound -mem 32
echo "   golden: $(wc -l < "$GOLDEN") records"

echo "== 2. build the +VEN_PS_PROXY (stall) TB =="
make -C "$REPO/verif/tb" proxy >/dev/null

echo "== 3. RTL lock-step through S_SYSCALL_WAIT (8-clock PS service latency) =="
"$REPO/verif/tb/obj_dir_proxy/tb_ventium" \
    --quake-image "$IMAGE" --lockstep "$GOLDEN" --out "$RTL" --max-insn "$N"

echo "== 4. grade: compare.py stalled-RTL vs golden =="
set +e
"$PY" "$REPO/verif/diff/compare.py" --mode func --all "$GOLDEN" "$RTL"
RC=$?
set -e
if [[ "$RC" == 0 ]]; then
  echo "QUAKE-LOCKSTEP-PROXY-OK: $N-insn prefix bit-exact through S_SYSCALL_WAIT (the gated stall preserves the architecture)"
else
  echo "QUAKE-LOCKSTEP-PROXY-DIVERGENT: the stall changed the trace (a S_SYSCALL_WAIT bug)"
fi
exit $RC
