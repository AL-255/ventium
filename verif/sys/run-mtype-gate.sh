#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW2_aug2 H-13: instruction-fetch cacheability must follow the PHYSICAL MEMORY
# TYPE, not CR0.CD alone.
#
# The icache retained every line it fetched, with no notion of what the chipset says
# about the address, so a line in a region the cacheability map marks non-cacheable was
# cached anyway and later fetches were served from a stale copy. ven_cachemap now
# supplies the memory type for the fetch address (is_code=1) and it is ORed into
# ic_fill_nocache beside the CR0.CD term.
#
# THE TEST executes a reuse-heavy loop from 0xA8000, inside the SMRAM/VGA aperture.
# With SMRAM closed (NB_SMRAM=0, the default) and the CPU outside SMM the map decodes
# that aperture as l1_cacheable=0 -- checked independently by run-cachemap-gate.sh's
# `smram_closed` case. So the lines must never be retained and every iteration refetches.
#
# TWO ASSERTIONS, and both are needed:
#   * the H-13 build must take MEASURABLY MORE CLOCKS (it is refetching), and
#   * the architectural result must be IDENTICAL. Honouring the memory type changes
#     only whether a line is kept, never what it computes. A gate that checked the
#     clock count alone would pass while the fix silently broke execution.
#
# MEASURED, not asserted: 37664 vs 32896 clocks (+14.5%), retired 2885 both ways,
# ebp=0x960 both ways.
#
# TWO THINGS THIS TEST NEEDED THAT ARE WORTH KNOWING, because without either it
# measures NOTHING and reports a confident pass:
#   1. --l1-axi. Without it l1axi_en=0, the L1/northbridge path is inert, core_req never
#      fires, and both builds are trivially identical. The first run of this comparison
#      did exactly that: 56208 reads on both sides.
#   2. The image must CLEAR CR0.CD. CR0 resets to 0x60000010 with CD set and no image in
#      this corpus clears it, so ic_fill_nocache is already 1 from the CR0 term and the
#      memory-type term ORs into an expression that is already true. The second run of
#      this comparison did that: 46752 reads on both sides.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TBD="$REPO/verif/tb"
IMG="$REPO/verif/sys/tests/pmtype/pmtype.bin"

echo "== REVIEW2_aug2 H-13: fetch cacheability follows the physical memory type =="
[[ -f "$IMG" ]] || { echo "  SKIP: pmtype.bin missing"; exit 0; }

make -s -C "$TBD" l1axi      >/dev/null 2>&1 || { echo "  FAIL: l1axi build";      echo "MTYPE-GATE-FAIL"; exit 1; }
make -s -C "$TBD" l1axi_nomt >/dev/null 2>&1 || { echo "  FAIL: l1axi_nomt build"; echo "MTYPE-GATE-FAIL"; exit 1; }

run() {  # $1 = objdir -> "clocks retired ebp"
  local tr out
  tr="$(mktemp)"
  out="$("$TBD/$1/tb_ventium" --image "$IMG" --system --l1-axi --out "$tr" \
         --max-insn 20000 --quiesce 400 2>&1 || true)"
  local c n e
  c="$(printf '%s' "$out" | grep -oE 'in [0-9]+ clocks' | grep -oE '[0-9]+' || echo 0)"
  n="$(printf '%s' "$out" | grep -oE 'retired [0-9]+'   | grep -oE '[0-9]+' || echo 0)"
  e="$(tail -1 "$tr" 2>/dev/null | grep -o '"ebp":"[^"]*"' | cut -d'"' -f4 || true)"
  rm -f "$tr"
  echo "$c $n ${e:-none}"
}

read -r C_ON  N_ON  E_ON  <<<"$(run obj_dir_l1axi)"
read -r C_OFF N_OFF E_OFF <<<"$(run obj_dir_l1axi_nomt)"

echo "  memory-type ON : clocks=$C_ON  retired=$N_ON  ebp=$E_ON"
echo "  memory-type OFF: clocks=$C_OFF retired=$N_OFF ebp=$E_OFF"

if [[ "$E_ON" != "0x00000960" ]]; then
  echo "  FAIL the loop did not run to completion (ebp != 0x960); the measurement below"
  echo "       would be meaningless."
  echo "MTYPE-GATE-FAIL"; exit 1
fi
if [[ "$E_ON" != "$E_OFF" || "$N_ON" != "$N_OFF" ]]; then
  echo "  FAIL honouring the memory type CHANGED THE ARCHITECTURAL RESULT. It must only"
  echo "       decide whether a line is retained, never what the code computes."
  echo "MTYPE-GATE-FAIL"; exit 1
fi
if (( C_ON <= C_OFF )); then
  echo "  FAIL no refetch: the uncacheable aperture is still being cached, so the"
  echo "       memory-type term is not reaching ic_fill_nocache. Check that the run"
  echo "       used --l1-axi and that the image clears CR0.CD -- either one alone makes"
  echo "       both builds identical and this comparison vacuous (see the header)."
  echo "MTYPE-GATE-FAIL"; exit 1
fi
echo "  ok   uncacheable code refetches (+$((C_ON - C_OFF)) clocks) and is architecturally identical"
echo "MTYPE-GATE-OK"; exit 0
