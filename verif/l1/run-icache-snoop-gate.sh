#!/usr/bin/env bash
# verif/l1/run-icache-snoop-gate.sh — Phase D.6 (mechanism) gate: the icache per-line
# snoop-invalidate. Builds tb_icache_snoop and asserts ICSNOOP-GATE-OK: a filled line is
# resident; a non-matching snoop leaves it; a matching snoop invalidates ONLY that way.
# (The top-level threading ven_northbridge.snoop_inv_* → core.u_icache requires editing
# ventium_top.sv and is a Phase E step.) Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

"$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    --top-module tb_icache_snoop -Mdir "$OBJ" -o tb_icache_snoop \
    "$ROOT/rtl/mem/icache.sv" "$ROOT/verif/l1/tb_icache_snoop.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "ICSNOOP-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_icache_snoop" 2>&1)"
echo "$OUT"
grep -q "ICSNOOP-GATE-OK" <<<"$OUT" || { echo "ICSNOOP-GATE-FAIL"; exit 1; }
echo "== icache snoop-invalidate mechanism gate PASS =="
