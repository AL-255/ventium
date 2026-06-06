#!/usr/bin/env bash
# run-verify-all.sh — Ventium TOP-LEVEL verification umbrella.
#
# One command that runs EVERY routinely-runnable gate and reports a single
# pass/fail summary. Until now the gates were partitioned into independent
# targets (make verify / verify-sys / verify-soc / verify-srt / m6 / bus /
# bus-sva), so a regression in (say) the bus-protocol SVA, the errata flag, or
# the SRT divider would NOT be caught by the routinely-run differential
# aggregates. `verify-all` closes that umbrella gap.
#
# Included gates (each is self-contained — builds what it needs):
#   1. verify     — FAST unified m1-m5 differential gate (func + cycle bands)
#   2. verify-sys — M2S system-mode oracle + RTL --system differential (11 tests)
#   3. verify-soc — M8 SoC regression aggregate (every ventium_soc gate)
#   4. verify-srt — radix-4 SRT divider bit-exactness (both PLAs)
#   5. m6         — M6 documented-errata self-checks (flag ON=defect / OFF=clean)
#   6. bus        — standalone biu_p5 protocol gate (19 SVA + 76 directed checks)
#   7. bus-sva    — INTEGRATED bus_mode=1 corpus run with the protocol SVA LIVE
#
# DELIBERATELY EXCLUDED (logged below, NOT silently dropped) — the m7 macro
# co-simulations depend on producer artifacts that are gitignored and cannot be
# regenerated from a clean checkout:
#   * m7 Quake lock-step  (needs the built Quake guest + shareware pak0.pak)
#   * m7 Win95 co-sim     (needs the rr-recorded replay.bin/overlay producer set)
# Run those manually after staging their producer inputs:
#   bash verif/m7/run-quake-lockstep.sh   /   bash verif/m7/win95/run-win95-cosim.sh
#
# Sequential (NOT parallel): the gates share build/ output dirs, the verif/tb
# obj_dirs, and gdbstub ports, so concurrent runs would race. Each gate is
# already internally parallel/cached where it can be.
#
# Exit 0 only if ALL included gates pass. Usage: bash verif/run-verify-all.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MK=(make -C "$REPO")

# name|make-target
GATES=(
  "verify    (m1-m5 differential func + cycle)|verify"
  "verify-sys (M2S system-mode + RTL --system diff)|verify-sys"
  "verify-soc (M8 SoC regression aggregate)|verify-soc"
  "verify-srt (radix-4 SRT divider, both PLAs)|verify-srt"
  "m6        (documented P5 errata self-checks)|m6"
  "bus       (standalone biu_p5 protocol gate)|bus"
  "bus-sva   (integrated bus_mode SVA corpus run)|bus-sva"
)

declare -a NAMES RESULTS
FAILED=0

echo "######################################################################"
echo "# Ventium verify-all — every routinely-runnable gate"
echo "######################################################################"
echo "# EXCLUDED (need gitignored producer artifacts; run manually):"
echo "#   - m7 Quake lock-step  (verif/m7/run-quake-lockstep.sh)"
echo "#   - m7 Win95 co-sim     (verif/m7/win95/run-win95-cosim.sh)"

for entry in "${GATES[@]}"; do
  name="${entry%%|*}"
  target="${entry##*|}"
  echo
  echo "==================== GATE: $name ===================="
  echo "---- make $target ----"
  if "${MK[@]}" "$target"; then
    NAMES+=("$name"); RESULTS+=("PASS")
  else
    NAMES+=("$name"); RESULTS+=("FAIL"); FAILED=1
  fi
done

echo
echo "######################################################################"
echo "# verify-all — SUMMARY"
echo "######################################################################"
for i in "${!NAMES[@]}"; do
  printf "  %-6s  %s\n" "${RESULTS[$i]}" "${NAMES[$i]}"
done
echo
echo "  (excluded, artifact-dependent: m7 Quake lock-step, m7 Win95 co-sim)"
echo
if [[ "$FAILED" == "0" ]]; then
  echo "VERIFY-ALL-OK  (every routinely-runnable Ventium gate PASSED)"
  exit 0
else
  echo "VERIFY-ALL: one or more gates FAILED (see above)"
  exit 1
fi
