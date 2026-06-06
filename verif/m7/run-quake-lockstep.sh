#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# M7.1 — Quake input-replay lock-step (docs/m7-lockstep-spec.md).
#
# Runs TyrQuake (the P5 static-ELF build in ventium-refs) on the Ventium RTL in
# lock-step against qemu-i386 8.2.2 (linux-user). QEMU is the golden + environment;
# the RTL is the CHECKED CPU; the int-0x80 proxy replays the kernel syscall effects
# (eax + kernel memory writes + the %gs TLS base) so the RTL never executes the
# kernel; compare.py grades ONLY the CPU architectural delta. A divergence = a real
# Ventium CPU bug.
#
#   bash verif/m7/run-quake-lockstep.sh [N_INSNS] [PORT]
#     N_INSNS  retired-instruction prefix to run (default 30000). The gdbstub
#              oracle is the throughput bound (~10k insn/s post-TCP_NODELAY), so a
#              full frame/timedemo is off the table; this runs the longest prefix
#              you budget for and reports bit-exactness + the first divergence.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$REPO/ventium-refs/07-p5-emulation-harness"
QEMU="$HARNESS/build/qemu/build/qemu-i386"
QBIN="$HARNESS/quake/bin/tyr-quake-p5"
QDATA="$HARNESS/quake"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
OUT="$REPO/build/m7"; mkdir -p "$OUT"
N="${1:-30000}"; PORT="${2:-52050}"
GOLDEN="$OUT/quake-startup.vtrace"; IMAGE="$OUT/quake-initial-image.json"
RTL="$OUT/quake-rtl.vtrace"
PY=/usr/bin/python3; command -v "$PY" >/dev/null || PY="$(command -v python3)"

[[ -x "$QBIN" ]] || { echo "missing guest: $QBIN (run ventium-refs quake/build-quake.sh)"; exit 1; }
[[ -f "$QDATA/id1/pak0.pak" ]] || { echo "missing shareware data (quake/fetch-quake.sh)"; exit 1; }

echo "== 1. producer: golden + initial image ($N insns, -seed 1234) =="
"$PY" "$GEN" --qemu "$QEMU" --syscall-proxy --elf "$QBIN" \
    --out "$GOLDEN" --image-out "$IMAGE" --max-insn "$N" --seed 1234 \
    --cpu pentium --port "$PORT" \
    --args -basedir "$QDATA" -noconinput -nosound -mem 32
echo "   golden: $(wc -l < "$GOLDEN") records ; image: $IMAGE"

echo "== 2. build the RTL TB =="
make -C "$REPO/verif/tb" rtl >/dev/null

echo "== 3. RTL lock-step (checked CPU; int-0x80 proxy replays kernel effects) =="
"$REPO/verif/tb/obj_dir/tb_ventium" \
    --quake-image "$IMAGE" --lockstep "$GOLDEN" --out "$RTL" --max-insn "$N"

echo "== 4. grade: compare.py RTL vs golden (CPU arch state only) =="
set +e
"$PY" "$REPO/verif/diff/compare.py" --mode func --all "$GOLDEN" "$RTL"
RC=$?
set -e
if [[ "$RC" == 0 ]]; then
  echo "QUAKE-LOCKSTEP-OK: $N-insn prefix EQUIVALENT (RTL bit-exact vs QEMU)"
else
  echo "QUAKE-LOCKSTEP-DIVERGENT: see the first-divergence record above (a CPU bug if not a harness issue)"
fi
exit $RC
