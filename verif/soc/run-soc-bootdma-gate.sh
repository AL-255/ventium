#!/usr/bin/env bash
# Ventium M9b — SoC DMA FIRST-BOOT gate (firmware stub chain-loads a real boot sector
# from the IDE disk with BUS-MASTER DMA and executes it), FULL PER-RECORD DIFFERENTIAL
# vs qemu-system.
#
# Same boot as the M9 PIO gate (run-soc-boot-gate.sh), but the -bios firmware
# (pboot_dma_stub.bin) loads the boot sector with a single-PRD READ DMA into RAM at
# 0x8000 instead of an inw drain, then FAR-JMPs into it. The boot sector (disk LBA0,
# pboot_mbr.bin — the SAME sector the PIO gate uses) then EXECUTES FROM RAM: it writes
# a 64-bit signature and exits via isa-debug-exit.
#
# The firmware sets nIEN FIRST (so NO IRQ14 ever fires -> the whole run is synchronous
# and per-record single-step differentiable) and uses the M8.4f single-PRD READ-DMA
# recipe — the only DMA shape that completes INLINE under qemu's block layer, so the
# gen_trace single-step golden (which has no main-loop AIO pump) still advances.
#
# Single-source disk (gen_disk.py): the boot sector is at LBA0 of BOTH pboot.img (qemu
# -drive) and pboot.disk.hex (ven_ide $readmemh), so they cannot drift. SHARED with the
# PIO M9 gate (same disk, same boot sector) — only the -bios firmware differs.
#
# NON-VACUOUS: the gate asserts the trace REACHES pc=0x00008000 (the boot sector
# executing from the RAM the DMA engine wrote -- proving the firmware->MBR handoff AND
# the DMA-write/instruction-fetch coherency, not a silent early halt), in ADDITION to
# the per-record EQUIVALENT. Zero new RTL: this runs on the existing ventium_soc +
# ven_ide DMA engine + the PCI shim + the flat TB memory (2-master mem mux).
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-bootdma-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/pboot"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

STUB="$TDIR/pboot_dma_stub.bin"                   # the 64 KiB BIOS firmware (the program)
MBR="$TDIR/pboot_mbr.bin"                          # the 512-byte boot sector (disk LBA0)
IMG_DISK="$TDIR/pboot.img"                          # the 64 KiB raw ATA disk image
DISK_HEX="$TDIR/pboot.disk.hex"                     # the RTL $readmemh backing store
GOLD_REF="$TDIR/pboot_dma.sys.vtrace.golden"        # committed reference (evidence)
GOLD_GEN="$OUTDIR/pboot_dma.sys.vtrace.golden"      # freshly regenerated this run
RTL_OUT="$OUTDIR/pboot_dma.rtl.soc.vtrace"
DRIVE="-drive if=ide,format=raw,index=0,file=$IMG_DISK,snapshot=on"
PORT="${PORT:-51261}"
MAXI=4000   # the DMA boot runs ~1090 instructions; ample headroom

say(){ echo; echo "=== $* ==="; }

# --- 0. build the DMA firmware stub + the boot sector, emit the single-source disk ---
say "0. build pboot_dma_stub.bin (-bios) + pboot_mbr.bin (boot sector) + the single-source disk"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$STUB" ]] || { echo "FATAL: firmware $STUB missing"; exit 1; }
[[ -f "$MBR"  ]] || { echo "FATAL: boot sector $MBR missing"; exit 1; }
"$PY" "$TDIR/gen_disk.py" --mbr "$MBR" --img "$IMG_DISK" --hex "$DISK_HEX"
"$PY" "$TDIR/gen_disk.py" --check --mbr "$MBR" --img "$IMG_DISK" --hex "$DISK_HEX"

# --- 1. build the ventium_soc --soc TB with the boot disk baked in ---------------
say "1. build the ventium_soc --soc TB (with -DVEN_IDE_DISK_HEX = the boot disk)"
make -C "$REPO/verif/tb" soc VEN_IDE_DISK_HEX="$DISK_HEX" >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }
echo "firmware: $STUB ($(stat -c%s "$STUB") bytes); boot sector: $MBR ($(stat -c%s "$MBR") bytes); disk: $IMG_DISK"
PRE_MD5="$(md5sum "$IMG_DISK" | cut -d' ' -f1)"

# --- 2. confirm the firmware boots to isa-debug-exit (the boot sector ran) -------
say "2. confirm pboot-dma boots to isa-debug-exit (code 133) under qemu-system-i386 + the IDE drive"
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing"; exit 1; }
set +e
timeout 30 "$QSYS" -display none -machine pc -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$STUB" $DRIVE >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "133" ]] || { echo "FATAL: boot reached qemu exit $RC, expected 133 (the boot sector's isa-debug-exit; did the DMA chain-load fail?)"; exit 1; }
echo "qemu-system exit code = $RC (the boot sector executed its isa-debug-exit): OK"

# --- 3. (re)generate the per-record golden (authoritative single-step oracle) ----
say "3. generate the per-record golden (gen_trace.py --system, qemu-system single-step, WITH the IDE drive)"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$STUB" --image-mode bios \
    --out "$GOLD_GEN" --port "$PORT" --max-insn "$MAXI" --args $DRIVE
echo "golden: $GOLD_GEN ($(wc -l < "$GOLD_GEN") lines)"

# NON-VACUOUS HANDOFF ASSERTION: the golden MUST contain a record at pc=0x00008000
# (the boot sector executing from RAM the DMA wrote). Without the firmware->MBR handoff
# there is no such record, so this guards against a silent early halt / a vacuous pass.
if grep -q '"pc":"0x00008000"' "$GOLD_GEN"; then
  echo "handoff assertion: golden REACHES pc=0x00008000 (boot sector executing from DMA-loaded RAM): OK"
else
  echo "FATAL: golden never reaches pc=0x00008000 -- the firmware->boot-sector DMA handoff did not happen"; exit 1
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

# the boot sector does not write the disk; the committed pboot.img must stay pristine.
POST_MD5="$(md5sum "$IMG_DISK" | cut -d' ' -f1)"
[[ "$POST_MD5" == "$PRE_MD5" ]] || { echo "FATAL: pboot.img MUTATED ($PRE_MD5 -> $POST_MD5); is snapshot=on on the -drive?"; exit 1; }
echo "disk pristine check: pboot.img md5 unchanged ($POST_MD5): OK"

# --- 4. run ventium_soc on the firmware -----------------------------------------
say "4. run ventium_soc on pboot_dma_stub.bin (firmware boots + DMA-chain-loads the disk sector)"
"$SOC_TB" --image "$STUB" --out "$RTL_OUT" \
    --max-insn "$MAXI" --max-cycles 2000000 --quiesce 300
echo "RTL soc trace: $RTL_OUT ($(wc -l < "$RTL_OUT") lines)"
grep -q '"pc":"0x00008000"' "$RTL_OUT" || { echo "FATAL: RTL trace never reaches pc=0x00008000 -- the SoC did not execute the DMA-loaded boot sector"; exit 1; }
echo "handoff assertion (RTL): ventium_soc REACHES pc=0x00008000 (boot sector executing from DMA-loaded RAM): OK"

# --- 5. per-record differential -------------------------------------------------
say "5. per-record differential (compare.py --mode func): golden vs RTL"
set +e
"$PY" "$REPO/verif/diff/compare.py" --mode func "$GOLD_GEN" "$RTL_OUT"
CMP=$?
set -e

echo
if [[ "$CMP" == "0" ]]; then
  echo "SOC-BOOTDMA-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  ventium_soc boots at the reset vector, chain-loads the boot sector from"
  echo "  IDE LBA0 via BUS-MASTER DMA into RAM 0x8000, and executes it (reaching"
  echo "  pc=0x8000 from the DMA-written RAM): byte-identical to qemu-system-i386"
  echo "  over all $(($(wc -l < "$RTL_OUT")-1)) retired instructions."
  echo
  echo "M9b SOC DMA FIRST-BOOT GATE: EQUIVALENT (per-record, full differential)"
else
  echo "M9b SOC DMA FIRST-BOOT GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
