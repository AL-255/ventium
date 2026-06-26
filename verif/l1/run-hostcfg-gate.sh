#!/usr/bin/env bash
# verif/l1/run-hostcfg-gate.sh — Phase D.4 gate: the TSC host-bridge PCI-config register
# file (ven_hostbridge_cfg) driving ven_cachemap. Builds tb_hostcfg and asserts
# HOSTCFG-GATE-OK: writing CC/PAM/DRAMC/DRB4 through the config port changes the cachemap's
# cacheability/routing decisions (FLCE enables caches, PAM shadows BIOS cacheable, HEN opens
# a hole, DRB4 sets top-of-memory) and config reads round-trip. Run from repo root.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

verilator --binary --assert -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME \
    -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT \
    --top-module tb_hostcfg -Mdir "$OBJ" -o tb_hostcfg \
    "$ROOT/rtl/northbridge/ven_hostbridge_cfg.sv" "$ROOT/rtl/northbridge/ven_cachemap.sv" \
    "$ROOT/verif/l1/tb_hostcfg.sv" > "$OBJ/build.log" 2>&1 \
    || { echo "HOSTCFG-GATE-FAIL (build)"; tail -40 "$OBJ/build.log"; exit 1; }

OUT="$("$OBJ/tb_hostcfg" 2>&1)"
echo "$OUT"
grep -q "HOSTCFG-GATE-OK" <<<"$OUT" || { echo "HOSTCFG-GATE-FAIL"; exit 1; }
echo "== host-bridge PCI-config → cachemap gate PASS =="
