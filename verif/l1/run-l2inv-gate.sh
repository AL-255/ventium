#!/usr/bin/env bash
# verif/l1/run-l2inv-gate.sh
# REVIEW1_Aug2 H-09: the ao486 L2 invalidation path must LOSE NOTHING, at any pulse
# rate, with no producer contract.
#
# The one-entry skid dropped invalidations two ways:
#   1. a second colliding pulse overwrote the single pending address;
#   2. with the tag port free and one pending, the mux picked the FRESH address while
#      the sequential block cleared the pending flag -- retiring it UNAPPLIED. Nothing
#      reported this one.
#
# A dropped invalidation leaves a stale line valid in L2, so a later read returns data
# another master has since overwritten: silent memory corruption. "Rare in practice" is
# not a defence, and a $display is not a fix.
#
# BOTH DIRECTIONS ARE RUN. The gate builds the testbench twice -- once with the pending
# BITMAP (must lose nothing) and once with +define+H09_BROKEN, which is the ORIGINAL
# skid verbatim (must lose the two documented cases). A gate that only ran the fixed
# build could not tell a real fix from a vacuous one.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT

build_run() {   # $1 = extra defines, $2 = subdir
  verilator --binary --timing -sv --assert -Wno-UNUSED -Wno-DECLFILENAME \
      -Wno-IMPLICITSTATIC $1 --top-module tb_l2_inv -Mdir "$OBJ/$2" -o tb \
      "$ROOT/verif/l1/tb_l2_inv.sv" > "$OBJ/$2.log" 2>&1 \
      || { echo "L2INV-GATE-FAIL (build $2)"; tail -20 "$OBJ/$2.log"; exit 1; }
  "$OBJ/$2/tb" 2>&1 | grep -vE "^- |Verilator:"
}

echo "=== 1. the FIX (pending bitmap): nothing may be lost ==="
OK_OUT="$(build_run "" ok)"
echo "$OK_OUT" | sed 's/^/  /'
if ! grep -q "L2INV-GATE-OK" <<<"$OK_OUT"; then
  echo "FATAL: the invalidation path lost a set. A dropped invalidation leaves a stale"
  echo "       L2 line valid -- a later read returns data another master overwrote."
  exit 1
fi

echo
echo "=== 2. the ORIGINAL skid must FAIL (proves the gate discriminates) ==="
BAD_OUT="$(build_run "-DH09_BROKEN" bad || true)"
echo "$BAD_OUT" | sed 's/^/  /'
if ! grep -q "L2INV-GATE-FAIL" <<<"$BAD_OUT"; then
  echo "FATAL: the ORIGINAL one-entry skid passed this gate. Then the gate does not"
  echo "       exercise the finding -- it cannot distinguish the fix from the defect,"
  echo "       which is the failure mode that made H-04's first gate worthless."
  exit 1
fi
LOST="$(sed -n 's/.*L2INV-GATE-FAIL (\([0-9]*\) set.*/\1/p' <<<"$BAD_OUT")"
echo "  the original skid lost ${LOST:-?} of the requested sets (both documented cases)"

echo
echo "L2INV-GATE-OK (lossless with the bitmap; the 1-deep skid demonstrably is not)"
