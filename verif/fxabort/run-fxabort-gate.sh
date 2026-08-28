#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# fxabort gate — the fragment-engine ABORT/RESET regression (the half that
# the differential system images cannot reach). Builds the fxprog driver
# image and the focused tb_fxabort (verilator --binary around the whole
# core, +define+VTM_NO_DPI) and runs:
#   * the RESET sweep: rst_n asserted while the engine sits in each active
#     phase (read frag1/frag2, write probe/fragA/fragB) -- the engine must
#     return to the one idle state with no shaping armed;
#   * the FAULT sweep with ack delays 0/1/3: write-probe #PF, read-frag2 #PF
#     (engine armed), read-frag1 #PF (pre-engagement miss -- never counted as
#     an engagement), exactly 7 engagements / 2 aborts per pass, no stale
#     shaping after an abort, clean completion to the DONE marker.
# The core's own sim-only checks (incl. the FX/ABORT assertions) run in this
# build; any of them firing fails the gate via the log grep below.
# Run from the repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

make -C "$ROOT/verif/fxabort" >/dev/null
python3 - "$ROOT/verif/fxabort/fxprog.bin" "$OBJ/fxprog.hex" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
with open(sys.argv[2], "w") as f:
    for b in data:
        f.write(f"{b:02x}\n")
PYEOF

verilator --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD -Wno-fatal \
    -Werror-UNOPTFLAT \
    --top-module tb_fxabort -Mdir "$OBJ" -o tb_fxabort \
    +define+VTM_NO_DPI -F "$ROOT/rtl/ventium.f" \
    "$ROOT/verif/fxabort/tb_fxabort.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "FXABORT-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$(cd "$OBJ" && ./tb_fxabort 2>&1)"
echo "$OUT"
# the core's sim-only assertions (FX/ABORT = the abort-cycle checks, plus any
# other core check / verilator assertion) must never fire
if grep -qE "FX/ABORT|%Error|FASTPATH/|FETCH/|ICACHE/|TLB/|WALK/" <<<"$OUT"; then
  echo "FXABORT-GATE-FAIL (an RTL sim-only check fired)"
  exit 1
fi
grep -q "FXABORT-GATE-OK" <<<"$OUT" || { echo "FXABORT-GATE-FAIL"; exit 1; }
grep -q "FXABORT-FAULT dly=0 OK" <<<"$OUT" || { echo "FXABORT-GATE-FAIL (same-cycle acks)"; exit 1; }
grep -q "FXABORT-FAULT dly=1 OK" <<<"$OUT" || { echo "FXABORT-GATE-FAIL (1-cycle acks)"; exit 1; }
grep -q "FXABORT-FAULT dly=3 OK" <<<"$OUT" || { echo "FXABORT-GATE-FAIL (3-cycle acks)"; exit 1; }
[ "$(grep -c 'FXABORT-RESET .* OK' <<<"$OUT")" == "5" ] || { echo "FXABORT-GATE-FAIL (reset sweep incomplete)"; exit 1; }
echo "== fxabort gate PASS =="
