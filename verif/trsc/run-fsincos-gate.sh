#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Iterative FSIN/FCOS engine gate: fpu_fsincos bit-exact vs the qref shared-poly
# silicon model (whose accuracy is ~1.8 ulp vs quad, qref --validate-trig).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="$(pwd)"; BUILD="$ROOT/build/trsc"; VERILATOR="${VERILATOR:-verilator}"
mkdir -p "$BUILD"
echo "=== FSINCOS gate: build qref + check model accuracy ==="
make -C tools/p5xtrans qref >/dev/null
tools/p5xtrans/qref --validate-trig

PASS_ALL=1
for SPEC in "0:--sweep-fsin:FSIN" "1:--sweep-fcos:FCOS"; do
  OP="${SPEC%%:*}"; rest="${SPEC#*:}"; FLAG="${rest%%:*}"; NAME="${rest##*:}"
  tools/p5xtrans/qref "$FLAG" > "$BUILD/fsincos.txt"
  awk '{print $1}' "$BUILD/fsincos.txt" > "$BUILD/fsincos_x.hex"
  awk '{print $2}' "$BUILD/fsincos.txt" > "$BUILD/fsincos_o.hex"
  N=$(wc -l < "$BUILD/fsincos.txt")
  echo "=== $NAME gate: op=$OP ($N vectors) ==="
  "$VERILATOR" --binary --timing --quiet -Wall -Wno-fatal \
    -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSED -Wno-DECLFILENAME -Wno-IMPLICITSTATIC \
    +define+FS_NV="$N" +define+FS_OP="$OP" -Mdir "$BUILD/objfs_$OP" --top-module tb_fsincos \
    -I"$ROOT/rtl/fpu" rtl/fpu/fpu_x87_pkg.sv rtl/fpu/fpu_fsincos.sv verif/trsc/tb_fsincos.sv >/dev/null
  OUT="$("$BUILD/objfs_$OP/Vtb_fsincos")"; echo "$OUT" | grep -E "FSINCOS-GATE"
  echo "$OUT" | grep -q "FSINCOS-GATE-OK" || PASS_ALL=0
done
[ "$PASS_ALL" = "1" ] || { echo "FSINCOS-GATE: FAIL"; exit 1; }
echo "FSINCOS-GATE: PASS (FSIN + FCOS bit-exact vs the qref shared-poly model)"
