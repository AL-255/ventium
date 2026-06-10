#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Run every PS-offload C-model cosim (each sw/ps_periph/<dev>.c proven bit-exact vs
# qemu when its device is PS-placed). Used by the soc-gate aggregate.
set -euo pipefail
HERE="$(dirname "${BASH_SOURCE[0]}")"
FAIL=0
for d in uart rtc i8042 acpipm fdc vga; do
  echo "==== PS-cosim: $d ===="
  bash "$HERE/run-soc-ps-cosim-gate.sh" "$d" || FAIL=1
done
[[ "$FAIL" == 0 ]] && echo "ALL-PS-COSIMS-OK (every C model == RTL == qemu)" || { echo "PS-COSIMS: FAIL"; exit 1; }
