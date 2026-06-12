#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium F3 — REAL SeaBIOS end-to-end boot gate: qemu's bios.bin POSTs on ventium_soc,
# reads a bootable disk sector via INT 13h, and JUMPs to it at 0000:7C00, which runs.
#
# This is the landmark F3 result: the UNMODIFIED qemu SeaBIOS (-bios bios.bin) runs its
# WHOLE power-on self-test on the Ventium core (real mode -> 32-bit protected-mode POST
# -> back to real mode, ~5.55M instructions), then performs the canonical PC boot — INT
# 13h reads disk LBA0 (served by the on-die ven_ide model from pboot_rm.disk.hex) into
# 0000:7C00, validates the 0x55AA signature, and far-jumps in. The boot sector
# (pboot_rm_mbr) then executes from RAM and writes its two deterministic 64-bit markers
# to physical 0x9000 / 0x9004 before isa-debug-exit. Observing those markers proves the
# ENTIRE chain ran: full SeaBIOS POST + the bootloader handoff + the boot sector itself.
#
# GATE SHAPE: free-run + marker (NOT per-record). A full SeaBIOS POST is not single-step
# differentiable past its fw_cfg / sti-driven init (the documented SSTEP_NOIRQ finding,
# and our fw_cfg file_dir is empty so the path diverges from qemu's anyway). So this gate
# does not diff per-record; it asserts the boot-sector MARKERS appear, which a stalled or
# crashed POST could never produce. The per-instruction CPU correctness underneath is
# covered by the per-record gates (psocrmint/psocrmexc/psocsregmem/psoccpuid/... + the
# 77/77 make verify). NON-VACUOUS: the two distinct markers (0x7C00B007 @0x9000 and
# 0x600DF00D @0x9004) are written ONLY by the booted sector, so a vacuous early stop fails.
#
# Requires qemu's SeaBIOS (ventium-refs submodule, proprietary). Skips cleanly if absent.
# Rebuilds the SoC TB with the BOOTABLE disk; a later default-disk gate rebuild self-heals.
# Usage: bash verif/soc/run-soc-seabios-boot-gate.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIOS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/pc-bios/bios.bin"
DISK="$REPO/verif/sys/tests/pboot/pboot_rm.disk.hex"
OUT="$REPO/build/soc"; mkdir -p "$OUT"

say(){ echo; echo "=== $* ==="; }

if [[ ! -f "$BIOS" ]]; then
  echo "SKIP: SeaBIOS $BIOS missing (ventium-refs submodule not present)"; exit 0
fi

say "0. build the bootable disk (pboot_rm.disk.hex: real-mode boot sector @ LBA0, 0x55AA)"
make -C "$REPO/verif/sys/tests/pboot" >/dev/null 2>&1 || true
[[ -f "$DISK" ]] || { echo "FATAL: bootable disk $DISK missing"; exit 1; }

say "1. build ventium_soc TB with the BOOTABLE disk (ven_ide \$readmemh = pboot_rm)"
make -C "$REPO/verif/tb" soc VEN_IDE_DISK_HEX="$DISK" >/dev/null 2>&1
TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$TB" ]] || { echo "FATAL: SoC TB not built"; exit 1; }

say "2. free-run qemu's SeaBIOS on ventium_soc to the boot-sector handoff"
"$TB" --image "$BIOS" --out "$OUT/seabios.boot.vtrace" \
    --max-insn 40000000 --max-cycles 3000000000 --quiesce 6000 --peek-mem $((0x9000)) 2>&1 \
    | grep -E "retired|peek-mem|0x00009000" | tee "$OUT/seabios.boot.log"
INSNS=$(grep -oE "retired [0-9]+" "$OUT/seabios.boot.log" | grep -oE "[0-9]+" | head -1)
echo "SeaBIOS retired ${INSNS:-?} instructions"

say "3. assert the boot-sector MARKERS (proves full POST + INT13 boot + sector ran)"
# pboot_rm_mbr writes 0x7C00B007 @0x9000 and 0x600DF00D @0x9004 (little-endian bytes).
LINE=$(grep "0x00009000:" "$OUT/seabios.boot.log" | tail -1)
echo "mem@0x9000: $LINE"
M0=$(echo "$LINE" | grep -oiE "07 b0 00 7c"); M1=$(echo "$LINE" | grep -oiE "0d f0 0d 60")
echo
if [[ -n "$M0" && -n "$M1" ]]; then
  echo "SOC-SEABIOS-BOOT-OK"
  echo "  qemu's unmodified SeaBIOS completed its FULL POST on ventium_soc (~${INSNS} insns),"
  echo "  read disk LBA0 via INT 13h, validated 0x55AA, far-jumped to 0000:7C00, and the boot"
  echo "  sector executed (markers 0x7C00B007 @0x9000 + 0x600DF00D @0x9004 present)."
  echo
  echo "F3 SeaBIOS end-to-end BOOT GATE: REACHED the booted sector"
  exit 0
else
  echo "F3 SeaBIOS boot GATE: FAIL — boot-sector markers not found (POST or boot handoff broke)"
  exit 1
fi
