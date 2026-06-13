#!/usr/bin/env bash
# verif/soc/run-soc-axil-gate.sh — unit gate for ven_soc_axil (KV260 PS<->PL bridge).
# Builds tb_ven_soc_axil with Verilator --binary and asserts SOCAXIL-GATE-OK (the
# AXI-Lite control/config/status/retire registers + the port-I/O capture/release
# handshake where the core stalls on io_ack until the PS services it). Run from repo root.
#
# Runs TWICE: the default (F2/F3) build, then the +VEN_PS_PROXY build which adds the
# int-0x80 syscall window (0x40-0x6C) directed phase [11]. Both must print -OK.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

run_one() {  # $1 = label, $2... = extra verilator defines
  local label="$1"; shift
  local mdir="$OBJ/$label"
  verilator --binary -sv --assert -Wno-UNUSED -Wno-DECLFILENAME \
      -Wno-INITIALDLY -Wno-IMPLICITSTATIC -Wno-WIDTHEXPAND "$@" \
      --top-module tb_ven_soc_axil -Mdir "$mdir" -o tb_ven_soc_axil \
      "$ROOT/rtl/soc/ven_soc_axil.sv" "$ROOT/verif/soc/tb_ven_soc_axil.sv" \
      > "$mdir.build.log" 2>&1 \
      || { echo "SOCAXIL-GATE-FAIL ($label build)"; tail -30 "$mdir.build.log"; exit 1; }
  local out
  out="$("$mdir/tb_ven_soc_axil" 2>&1)"
  echo "---- $label ----"
  echo "$out"
  grep -q "SOCAXIL-GATE-OK" <<<"$out" || { echo "SOCAXIL-GATE-FAIL ($label)"; exit 1; }
}

run_one default
run_one proxy +define+VEN_PS_PROXY
echo "== ven_soc_axil unit gate PASS (default + VEN_PS_PROXY) =="
