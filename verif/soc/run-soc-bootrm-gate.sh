#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium M9-rm — SoC CANONICAL REAL-MODE BOOT gate (a real-mode firmware stub chain-loads
# a real boot sector from the IDE disk to 0000:7C00 and executes it), FULL PER-RECORD
# DIFFERENTIAL vs qemu-system.
#
# The canonical PC boot. Unlike the M9 PIO gate (real->protected, load to 0x8000), the -bios
# firmware (pboot_rm_stub.bin) STAYS in 16-bit real mode the whole time: it boots at the reset
# vector F000:FFF0, sets nIEN (so NO IRQ14 ever fires -> the run is synchronous and per-record
# single-step differentiable), READ SECTORS (0x20) disk LBA0 via 16-bit PIO into RAM at the
# canonical real-mode boot address 0000:7C00, and FAR-JMPs into it. The boot sector (disk LBA0,
# pboot_rm_mbr.bin) then EXECUTES FROM RAM in 16-bit real mode (cs=0, ip=0x7C00): it writes a
# 64-bit signature and exits via isa-debug-exit.
#
# Single-source disk (gen_disk.py): the real-mode boot sector is at LBA0 of BOTH pboot_rm.img
# (qemu -drive) and pboot_rm.disk.hex (ven_ide $readmemh), so they cannot drift. Distinct disk
# names from the M9/M9b gates so the three boot gates never share an image.
#
# NON-VACUOUS: the gate asserts the trace REACHES pc=0x00007c00 (the boot sector executing from
# RAM at the canonical entry -- proving the firmware->MBR handoff actually happened, not a silent
# early halt), in ADDITION to the per-record EQUIVALENT. The trace pc is the raw segment offset
# (eip); the boot sector runs at cs=0/ip=0x7C00 so pc==linear==0x7C00. Zero new RTL: this runs on
# the existing ventium_soc + ven_ide PIO read path + the flat TB memory. cr0 stays the reset
# 0x60000010 for every record (M9-rm never enters protected mode) -- strictly simpler than M9.
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-bootrm-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/pboot"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

STUB="$TDIR/pboot_rm_stub.bin"                    # the 64 KiB real-mode BIOS firmware
MBR="$TDIR/pboot_rm_mbr.bin"                       # the 512-byte real-mode boot sector (disk LBA0)
IMG_DISK="$TDIR/pboot_rm.img"                       # the 64 KiB raw ATA disk image
DISK_HEX="$TDIR/pboot_rm.disk.hex"                  # the RTL $readmemh backing store
GOLD_REF="$TDIR/pboot_rm.sys.vtrace.golden"         # committed reference (evidence)
GOLD_GEN="$OUTDIR/pboot_rm.sys.vtrace.golden"       # freshly regenerated this run
RTL_OUT="$OUTDIR/pboot_rm.rtl.soc.vtrace"
DRIVE="-drive if=ide,format=raw,index=0,file=$IMG_DISK,snapshot=on"
PORT="${PORT:-51262}"
MAXI=4000   # the real-mode boot runs FEWER instructions than M9 (no GDT/PM transition)

say(){ echo; echo "=== $* ==="; }

# --- 0. build the real-mode firmware + boot sector, emit the single-source disk ---
say "0. build pboot_rm_stub.bin (-bios) + pboot_rm_mbr.bin (real-mode boot sector) + the disk"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$STUB" ]] || { echo "FATAL: firmware $STUB missing"; exit 1; }
[[ -f "$MBR"  ]] || { echo "FATAL: boot sector $MBR missing"; exit 1; }
"$PY" "$TDIR/gen_disk.py" --mbr "$MBR" --img "$IMG_DISK" --hex "$DISK_HEX"
"$PY" "$TDIR/gen_disk.py" --check --mbr "$MBR" --img "$IMG_DISK" --hex "$DISK_HEX"

# --- 1. build the ventium_soc --soc TB with the real-mode boot disk baked in -------
say "1. build the ventium_soc --soc TB (with -DVEN_IDE_DISK_HEX = the real-mode boot disk)"
make -C "$REPO/verif/tb" soc VEN_IDE_DISK_HEX="$DISK_HEX" >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }
echo "firmware: $STUB ($(stat -c%s "$STUB") bytes); boot sector: $MBR ($(stat -c%s "$MBR") bytes); disk: $IMG_DISK"
PRE_MD5="$(md5sum "$IMG_DISK" | cut -d' ' -f1)"

# --- 2. confirm the firmware boots to isa-debug-exit (the boot sector ran) -------
say "2. confirm pboot-rm boots to isa-debug-exit (code 133) under qemu-system-i386 + the IDE drive"
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing"; exit 1; }
set +e
timeout 30 "$QSYS" -display none -machine pc -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$STUB" $DRIVE >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "133" ]] || { echo "FATAL: boot reached qemu exit $RC, expected 133 (the boot sector's isa-debug-exit; did the real-mode chain-load fail?)"; exit 1; }
echo "qemu-system exit code = $RC (the real-mode boot sector executed its isa-debug-exit): OK"

# --- 3. (re)generate the per-record golden (authoritative single-step oracle) ----
say "3. generate the per-record golden (gen_trace.py --system, qemu-system single-step, WITH the IDE drive)"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$STUB" --image-mode bios \
    --out "$GOLD_GEN" --port "$PORT" --max-insn "$MAXI" --args $DRIVE
echo "golden: $GOLD_GEN ($(wc -l < "$GOLD_GEN") lines)"

# NON-VACUOUS HANDOFF ASSERTION: the golden MUST contain a record at pc=0x00007c00
# (the real-mode boot sector executing at the canonical entry). Without the firmware->MBR
# handoff there is no such record, so this guards against a silent early halt / a vacuous pass.
if grep -q '"pc":"0x00007c00"' "$GOLD_GEN"; then
  echo "handoff assertion: golden REACHES pc=0x00007c00 (real-mode boot sector executing at 0000:7C00): OK"
else
  echo "FATAL: golden never reaches pc=0x00007c00 -- the firmware->boot-sector handoff did not happen"; exit 1
fi

# drift check vs the committed reference golden (records, skipping the note line).
if [[ -f "$GOLD_REF" ]]; then
  if diff -q <(tail -n +2 "$GOLD_REF") <(tail -n +2 "$GOLD_GEN") >/dev/null 2>&1; then
    echo "golden drift check: records identical to committed $GOLD_REF: OK"
  else
    echo "NOTE: regenerated golden records differ from the committed reference"
    echo "      ($GOLD_REF) -- the live oracle below is authoritative. Inspect if unexpected."
  fi
fi

# the boot sector does not write the disk; the committed pboot_rm.img must stay pristine.
POST_MD5="$(md5sum "$IMG_DISK" | cut -d' ' -f1)"
[[ "$POST_MD5" == "$PRE_MD5" ]] || { echo "FATAL: pboot_rm.img MUTATED ($PRE_MD5 -> $POST_MD5); is snapshot=on on the -drive?"; exit 1; }
echo "disk pristine check: pboot_rm.img md5 unchanged ($POST_MD5): OK"

# --- 4. run ventium_soc on the firmware -----------------------------------------
say "4. run ventium_soc on pboot_rm_stub.bin (real-mode firmware boots + chain-loads to 0000:7C00)"
"$SOC_TB" --image "$STUB" --out "$RTL_OUT" \
    --max-insn "$MAXI" --max-cycles 2000000 --quiesce 300
echo "RTL soc trace: $RTL_OUT ($(wc -l < "$RTL_OUT") lines)"
grep -q '"pc":"0x00007c00"' "$RTL_OUT" || { echo "FATAL: RTL trace never reaches pc=0x00007c00 -- the SoC did not execute the boot sector"; exit 1; }
echo "handoff assertion (RTL): ventium_soc REACHES pc=0x00007c00 (real-mode boot sector executing): OK"

# --- 5. per-record differential -------------------------------------------------
say "5. per-record differential (compare.py --mode func): golden vs RTL"
set +e
"$PY" "$REPO/verif/diff/compare.py" --mode func "$GOLD_GEN" "$RTL_OUT"
CMP=$?
set -e

echo
if [[ "$CMP" == "0" ]]; then
  echo "SOC-BOOTRM-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  ventium_soc boots at the reset vector, STAYS in 16-bit real mode, chain-loads the"
  echo "  boot sector from IDE LBA0 via PIO into RAM 0000:7C00, and executes it (reaching"
  echo "  pc=0x7C00 from RAM): byte-identical to qemu-system-i386 over all"
  echo "  $(($(wc -l < "$RTL_OUT")-1)) retired instructions."
  echo
  echo "M9-rm CANONICAL REAL-MODE BOOT GATE: EQUIVALENT (per-record, full differential)"
else
  echo "M9-rm CANONICAL REAL-MODE BOOT GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
