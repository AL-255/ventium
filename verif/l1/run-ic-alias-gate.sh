#!/usr/bin/env bash
# verif/l1/run-ic-alias-gate.sh
# REVIEW1_Aug2 H-05: linear I-cache tags are incoherent across CPU virtual ALIASES.
#
# The I-cache is tagged by LINEAR fetch address; a CPU store snoops with the store's
# LINEAR address (ventium_l1_axi.sv:333). If one physical page is mapped by two linear
# addresses, a store through alias B invalidates only B -- and a STALE EXECUTABLE copy
# stays resident under A and is fetched and executed. Self-modifying code, a loader
# writing code through a scratch mapping, and A20 mask changes all produce this shape.
#
# The review names three remedies: physical I-tags, a reverse-alias mechanism, or
# "flushing all executable state on every CPU store would be correct but expensive".
# VEN_IC_ALIAS_SAFE is the third. THE REAL FIX IS PHYSICAL I-TAGS AND IS NOT DONE.
#
# This gate runs BOTH builds, and asserts a different thing of each:
#   default            the hazard MUST reproduce. If it stops reproducing, this gate has
#                      stopped exercising the finding and must not keep printing OK.
#   VEN_IC_ALIAS_SAFE  the aliased line MUST be dropped.
# Both runs also check the control (a store to a line invalidates THAT line), so a
# build that cached nothing could not pass either direction by accident.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBJ="$(mktemp -d)"; trap 'rm -rf "$OBJ"' EXIT

VFLAGS="--binary -sv --assert -Wno-fatal -Wno-UNUSED -Wno-DECLFILENAME -Wno-IMPLICITSTATIC
        -Wno-WIDTH -Wno-UNOPTFLAT -Wno-BLKSEQ"

run() {  # $1 = defines, $2 = dir
  verilator $VFLAGS $1 --top-module tb_ic_alias -Mdir "$OBJ/$2" -o tb \
      "$ROOT/rtl/mem/icache.sv" "$ROOT/verif/l1/tb_ic_alias.sv" > "$OBJ/$2.log" 2>&1 \
      || { echo "ICALIAS-GATE-FAIL (build $2)"; tail -20 "$OBJ/$2.log"; exit 1; }
  "$OBJ/$2/tb" 2>&1 | grep -vE "^- |Verilator:"
}

echo "=== 1. DEFAULT build: the alias hazard must still REPRODUCE ==="
D="$(run "" def)"; echo "$D" | sed 's/^/  /'
grep -q "ICALIAS-GATE-OK" <<<"$D" || { echo "FATAL: control broken in the default build"; exit 1; }
grep -q "HAZARD CONFIRMED" <<<"$D" || {
  echo "FATAL: the default build no longer exhibits the alias hazard. Either it was"
  echo "       fixed properly (then update this gate and the docs) or the gate stopped"
  echo "       exercising it. Either way it must not silently keep reporting OK."
  exit 1; }

echo
echo "=== 2. VEN_IC_ALIAS_SAFE: the aliased line must be DROPPED ==="
S="$(run "-DVEN_IC_ALIAS_SAFE" safe)"; echo "$S" | sed 's/^/  /'
grep -q "ICALIAS-GATE-OK" <<<"$S" || {
  echo "FATAL: with VEN_IC_ALIAS_SAFE a store through one alias did NOT drop the other."
  exit 1; }

echo
echo "ICALIAS-GATE-OK (hazard reproduced in the default build; VEN_IC_ALIAS_SAFE removes it)"
