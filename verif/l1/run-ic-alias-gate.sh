#!/usr/bin/env bash
# verif/l1/run-ic-alias-gate.sh
# REVIEW1_Aug2 H-05 / REVIEW1_Aug3 R2-H09: I-cache coherence across CPU virtual
# ALIASES -- FIXED by physical snoop tags.
#
# The I-cache lookup is tagged by LINEAR fetch address (VIPT: the set index is
# page-offset bits, identical in both domains), and each line now also records
# its PHYSICAL page tag (ic_ptag, captured from fill_ptag at fill_done). CPU
# store snoops carry the store's PHYSICAL address (core_addr in ventium_l1_axi;
# post-mem_xlate mem_addr for the core-internal smc path), so a store through
# ANY alias of a physical line drops every aliased copy. Remaps are covered by
# the I-cache flush on tlb_flush, A20 by a20_flush, DMA by the physical port-0
# match (and the conservative paging_on full flush, kept as belt-and-braces).
# Decoded state dies under the same identity: the snoop match is forwarded to
# the uopcache's invalidate ports.
#
# This gate runs THREE builds and asserts a different thing of each:
#   default              the alias line is DROPPED (the fix works), and the
#                        physical match is reported on the snoop1_* outputs
#                        (the uopcache hookup).
#   VEN_IC_SNOOP_LINEAR  the legacy linear compare returns and the hazard MUST
#                        reproduce -- the gate's discrimination control. If the
#                        hazard cannot be reproduced here, the default-build
#                        check above proves nothing.
#   VEN_IC_ALIAS_SAFE    the conservative full flush still drops the line.
# All runs also check the control (a store to a line invalidates THAT line), so
# a build that cached nothing could not pass any direction by accident.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT

VFLAGS="--binary -sv --assert -Wno-fatal -Wno-UNUSED -Wno-DECLFILENAME -Wno-IMPLICITSTATIC
        -Wno-WIDTH -Wno-UNOPTFLAT -Wno-BLKSEQ"

run() {  # $1 = defines, $2 = dir
  "$ROOT/tools/verilator_serial.sh" -j "${VL_J:-1}" $VFLAGS $1 --top-module tb_ic_alias -Mdir "$OBJ/$2" -o tb \
      "$ROOT/rtl/mem/icache.sv" "$ROOT/verif/l1/tb_ic_alias.sv" > "$OBJ/$2.log" 2>&1 \
      || { echo "ICALIAS-GATE-FAIL (build $2)"; tail -20 "$OBJ/$2.log"; exit 1; }
  "$OBJ/$2/tb" 2>&1 | grep -vE "^- |Verilator:"
}

echo "=== 1. DEFAULT build: physical snoop tags drop the aliased line ==="
D="$(run "" def)"; echo "$D" | sed 's/^/  /'
grep -q "ICALIAS-GATE-OK" <<<"$D" || {
  echo "FATAL: the default build failed -- either a store through one alias did"
  echo "       NOT drop the line fetched through the other (the R2-H09 physical"
  echo "       snoop tags regressed), or the same-line control broke."
  exit 1; }

echo
echo "=== 2. VEN_IC_SNOOP_LINEAR control: the hazard MUST reproduce ==="
L="$(run "-DVEN_IC_SNOOP_LINEAR" lin)"; echo "$L" | sed 's/^/  /'
grep -q "ICALIAS-GATE-OK" <<<"$L" || { echo "FATAL: control broken in the linear build"; exit 1; }
grep -q "HAZARD REPRODUCED" <<<"$L" || {
  echo "FATAL: the legacy linear-compare build no longer exhibits the alias"
  echo "       hazard, so the default-build check cannot distinguish fix from"
  echo "       defect. Re-diagnose before this gate may report OK."
  exit 1; }

echo
echo "=== 3. VEN_IC_ALIAS_SAFE: the aliased line must be DROPPED ==="
S="$(run "-DVEN_IC_ALIAS_SAFE" safe)"; echo "$S" | sed 's/^/  /'
grep -q "ICALIAS-GATE-OK" <<<"$S" || {
  echo "FATAL: with VEN_IC_ALIAS_SAFE a store through one alias did NOT drop the other."
  exit 1; }

echo
echo "ICALIAS-GATE-OK (physical snoop tags drop aliased lines; the linear-compare"
echo "                 control reproduces the hazard; ALIAS_SAFE still correct)"
