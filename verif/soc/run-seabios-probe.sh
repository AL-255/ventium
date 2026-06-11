#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Ventium F3 — SeaBIOS POST gap-walker. Free-runs qemu's real SeaBIOS on ventium_soc
# and per-record-diffs the early (pre-IRQ) POST against a qemu-system single-step
# golden to find the FIRST divergence = the next gap to fix. Not a pass/fail gate yet
# (a full SeaBIOS POST is not single-step differentiable past the IRQ-driven init --
# see the pirqsoc SSTEP_NOIRQ finding); it is the gap-finding loop: diff -> fix ->
# re-run. Usage: bash verif/soc/run-seabios-probe.sh [N_golden]
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
BIOS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/pc-bios/bios.bin"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3; command -v "$PY" >/dev/null || PY="$(command -v python3)"
N="${1:-42000}"; OUT="$REPO/build/soc"; mkdir -p "$OUT"
[[ -x "$BIOS" || -f "$BIOS" ]] || { echo "FATAL: SeaBIOS $BIOS missing (ventium-refs submodule)"; exit 1; }

echo "=== 1. build ventium_soc TB ==="
make -C "$REPO/verif/tb" soc >/dev/null 2>&1
TB="$REPO/verif/tb/obj_dir_soc/tb_soc"

echo "=== 2. qemu SeaBIOS single-step golden ($N records) ==="
"$PY" "$GEN" --qemu "$QSYS" --system --image "$BIOS" --image-mode bios \
    --out "$OUT/seabios.golden" --port "${PORT:-51299}" --max-insn "$N" --cpu pentium 2>&1 | tail -1

echo "=== 3. RTL free-run on ventium_soc ==="
"$TB" --image "$BIOS" --out "$OUT/seabios.rtl.vtrace" \
    --max-insn "$((N+5000))" --max-cycles 60000000 --quiesce 500 2>&1 | grep -E "retired|alias|stop:"

echo "=== 4. first divergence (= the next gap) ==="
"$PY" "$REPO/verif/diff/compare.py" --mode func "$OUT/seabios.golden" "$OUT/seabios.rtl.vtrace" 2>&1 | tail -4
