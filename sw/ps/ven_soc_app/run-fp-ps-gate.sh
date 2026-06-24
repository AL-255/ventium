#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-fp-ps-gate.sh — host smoke gate for the FP_PS_ALL x87 dispatcher (ven_fp_ps.c).
# Builds + runs test_fp_ps.c against the Berkeley SoftFloat-3e extF80 library that
# verif/fpu87 already builds. Exits non-zero on any mismatch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SF="$HERE/../../../verif/fpu87"
SF_INC="$SF/extern/berkeley-softfloat-3/source/include"
SF_PLAT="$SF/build/softfloat"
SF_LIB="$SF/build/softfloat/softfloat.a"

if [ ! -f "$SF_LIB" ]; then
  echo "building SoftFloat library (verif/fpu87) ..."
  make -C "$SF" >/dev/null
fi

OUT=$(mktemp -d)
gcc -O2 -std=c11 -DSOFTFLOAT_FAST_INT64 -DLITTLEENDIAN=1 \
    -I"$SF_INC" -I"$SF_PLAT" -I"$HERE/../../ps_periph" \
    "$HERE/test_fp_ps.c" "$HERE/ven_fp_ps.c" "$SF_LIB" -lm -o "$OUT/test_fp_ps"
"$OUT/test_fp_ps"
