#!/usr/bin/env bash
# run-all-soc-gates.sh — Ventium M8 SoC regression aggregate.
#
# Runs EVERY ventium_soc differential gate in sequence and reports a pass/fail
# summary. This is the SoC analogue of `make verify` / `make verify-sys`: a
# single command that re-checks the WHOLE self-contained-SoC track after any
# change to rtl/soc/ventium_soc.sv (or a wired device model), so a SoC
# regression cannot slip through by only running one gate.
#
# The gates, in order (each is a self-contained build + qemu-system oracle +
# ventium_soc run + compare.py):
#   1. pirqsoc  (M8.1) — PIC+PIT on-die IRQ0       : CHECKPOINT-differential
#   2. psocdev  (M8.2) — RTC+8042+port92+A20        : per-record differential
#   3. pvga     (M8.3) — VGA regfile + ACPI-PM      : per-record differential
#   4. pide     (M8.4/d2/e/e2/f + M8.5) — IDE/ATAPI/DMA/block-PIO + PCI enum
#   5. pboot    (M9)   — first boot: firmware chain-loads a boot sector from disk
#   6. test386         — external x86 CPU tester    : per-record differential
#
# Sequential (NOT parallel): the gates share the tb_soc obj_dir + the build/soc
# output dir + a qemu gdbstub port, so concurrent runs would race. Each gate is
# fast; the whole suite is a few minutes.
#
# Exit 0 only if ALL gates pass. Usage: bash verif/soc/run-all-soc-gates.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# name|script   (script path relative to REPO)
GATES=(
  "pirqsoc (M8.1 PIC+PIT)|verif/soc/run-soc-gate.sh"
  "psocdev (M8.2 RTC/8042/port92/A20)|verif/soc/run-soc-dev-gate.sh"
  "pvga    (M8.3 VGA + ACPI-PM)|verif/soc/run-soc-vga-gate.sh"
  "pide    (M8.4 IDE/ATA primary master PIO)|verif/soc/run-soc-ide-gate.sh"
  "pboot   (M9 first boot: chain-load from disk)|verif/soc/run-soc-boot-gate.sh"
  "test386 (external CPU tester)|verif/external/test386/run-test386-gate.sh"
)

declare -a NAMES RESULTS
FAILED=0

echo "######################################################################"
echo "# Ventium SoC regression aggregate — all ventium_soc differential gates"
echo "######################################################################"

for entry in "${GATES[@]}"; do
  name="${entry%%|*}"
  script="${entry##*|}"
  echo
  echo "==================== GATE: $name ===================="
  echo "---- $script ----"
  if [[ ! -f "$REPO/$script" ]]; then
    echo "MISSING: $REPO/$script"
    NAMES+=("$name"); RESULTS+=("MISSING"); FAILED=1
    continue
  fi
  if bash "$REPO/$script"; then
    NAMES+=("$name"); RESULTS+=("PASS")
  else
    NAMES+=("$name"); RESULTS+=("FAIL"); FAILED=1
  fi
done

echo
echo "######################################################################"
echo "# SoC regression aggregate — SUMMARY"
echo "######################################################################"
for i in "${!NAMES[@]}"; do
  printf "  %-8s  %s\n" "${RESULTS[$i]}" "${NAMES[$i]}"
done
echo
if [[ "$FAILED" == "0" ]]; then
  echo "ALL-SOC-GATES-OK  (every ventium_soc differential gate EQUIVALENT)"
  exit 0
else
  echo "SOC REGRESSION: one or more gates FAILED (see above)"
  exit 1
fi
