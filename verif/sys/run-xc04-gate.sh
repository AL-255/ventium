#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# REVIEW2_aug2 C-04: a DIRECTED page-crossing case for a non-split-capable producer.
#
# The finding says the split covers only S_LOAD/S_LOAD2/S_STORE, and that the measured
# "0 reachable in 68 images" establishes CORPUS COVERAGE, not architectural
# unreachability. It asks for "directed boundary cases for each request producer, not
# only the three common states". This is that case for S_LGDT.
#
# THIS GATE ASSERTS THAT THE CORE'S OWN PAGING/C-04 ASSERTION FIRES. That is deliberate
# and follows run-ic-alias-gate.sh, which likewise requires the default build to still
# exhibit its hazard: the point is to hold the REACHABILITY answer, so that if the split
# is ever extended to cover S_LGDT this gate FAILS and forces the claim to be restated
# rather than quietly going green.
#
#   fires  -> S_LGDT is architecturally reachable with a crossing extent   PASS
#   silent -> either the producer was fixed (restate this gate) or the probe
#             stopped reaching the crossing (the test regressed)           FAIL
#
# pxc04 is built on pfault, NOT pxpage, because pfault installs an IDT: an earlier
# attempt on pxpage could not distinguish "crossed undetected" from "faulted with
# nowhere to go". Both pages here are identity-mapped P|RW, so no #PF is involved.
#
# Kept OUT of the seg gate's corpus sweep (which fails on a nonzero PAGING/C-0* count)
# and out of verify-sys's explicit golden list.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TB="$REPO/verif/tb/${OBJDIR:-obj_dir}/tb_ventium"
IMG="$REPO/verif/sys/tests/pxc04/pxc04.bin"

echo "== REVIEW2_aug2 C-04: is a non-split-capable producer REACHABLE? =="
[[ -x "$TB"  ]] || { echo "  SKIP: $TB missing"; exit 0; }
[[ -f "$IMG" ]] || { echo "  SKIP: pxc04.bin missing"; exit 0; }

OUT="$("$TB" --image "$IMG" --system --out /dev/null --max-insn 4000 --quiesce 400 2>&1 || true)"
LINE="$(printf '%s\n' "$OUT" | grep -o 'PAGING/C-04: UNSPLIT page-crossing access in state [0-9]*' | head -1 || true)"

if [[ -n "$LINE" ]]; then
  echo "  $LINE"
  echo "  ok   the crossing IS reachable -- 'not observed in the corpus' is coverage,"
  echo "       not unreachability, exactly as the finding says"
  echo "XC04-GATE-OK"; exit 0
fi
echo "  FAIL the PAGING/C-04 assertion did NOT fire."
echo "       Either the split now covers this producer -- in which case this gate has"
echo "       served its purpose and must be restated -- or the probe no longer reaches"
echo "       the crossing, which means the TEST regressed, not the core."
echo "XC04-GATE-FAIL"; exit 1
