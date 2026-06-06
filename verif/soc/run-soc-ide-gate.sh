#!/usr/bin/env bash
# Ventium M8.4a — SoC IDE/ATA gate (primary master, PIO: IDENTIFY + READ SECTORS
# + DIAGNOSTIC + absent-slave + reset signature).
#
# FULL PER-RECORD DIFFERENTIAL — like the M8.3 pvga gate. The pide test sets nIEN
# (0x3F6 bit1) FIRST, so NO IRQ14 is ever delivered: every interaction is a
# synchronous IN/OUT or a polled-status read. The standard gen_trace.py --system
# single-step golden is a valid PER-RECORD oracle (the SSTEP_NOIRQ HW-IRQ masking
# is structurally irrelevant — no IRQ is raised) and the gate is plain compare.py
# EQUIVALENT, running on ventium_soc (with the M8.4 IDE device).
#
# The KEY ingredient: a SINGLE-SOURCE-OF-TRUTH disk image. gen_disk.py emits BOTH
#   * pide.img      -> qemu-system via -drive if=ide,format=raw,index=0,file=...
#   * pide.disk.hex -> ven_ide via $readmemh
# from one byte buffer, so the qemu backing image and the RTL backing store
# cannot drift (a build-time md5-equivalent drift assert confirms it). The READ
# SECTORS data is therefore byte-identical on both sides by construction.
#
# What it proves, byte-identical to qemu-system-i386 8.2.2 over every retired
# instruction:
#   * reset signature (status 0x50, error 0x00, nsector/sector 1, devhead 0xA0),
#   * absent-slave masking (status/error/alt-status read 0x00 for the selected
#     absent slave; only those three masked — qemu core.c ide_ioport_read),
#   * IDENTIFY DEVICE (0xEC): 256 words (geometry COMPUTED from parameters; the
#     model/serial/firmware strings + feature words config-pinned to qemu 8.2.2),
#   * READ SECTORS (0x20) LBA 0 and LBA 127: 256 words each, byte-identical to
#     the single-source disk image (proves LBA->offset addressing),
#   * EXECUTE DEVICE DIAGNOSTIC (0x90): error 0x01, devhead 0xA0.
#
# Drive presence is MANDATORY: with no -drive, qemu aborts IDENTIFY/READ (status
# 0x41) — so Stages 2+3 HARD-FAIL if the drive is missing.
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-ide-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/pide"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

IMG="$TDIR/pide.bin"                          # the 64 KiB BIOS image (the program)
IMG_DISK="$TDIR/pide.img"                      # the 64 KiB raw ATA disk image
DISK_HEX="$TDIR/pide.disk.hex"                 # the RTL $readmemh backing store
GOLD_REF="$TDIR/pide.sys.vtrace.golden"        # committed reference (evidence)
GOLD_GEN="$OUTDIR/pide.sys.vtrace.golden"      # freshly regenerated this run
RTL_OUT="$OUTDIR/pide.rtl.soc.vtrace"
# snapshot=on: M8.4b WRITE SECTORS mutates the disk; route guest writes to an
# anonymous temp overlay so the committed single-source pide.img stays read-only
# (the write only needs to survive within one run — both the qemu overlay and the
# RTL in-memory disk[] provide that). An md5 PRE==POST assert (below) enforces it.
DRIVE="-drive if=ide,format=raw,index=0,file=$IMG_DISK,snapshot=on"
PORT="${PORT:-51200}"
MAXI=23000   # M8.4a+b reads/writes + M8.4c fidelity + mid-DRQ guard

say(){ echo; echo "=== $* ==="; }

# --- 0. single-source disk: emit pide.img + pide.disk.hex, drift-assert --------
say "0. generate the single-source disk (pide.img + pide.disk.hex) + drift assert"
"$PY" "$TDIR/gen_disk.py" --img "$IMG_DISK" --hex "$DISK_HEX"
"$PY" "$TDIR/gen_disk.py" --check --img "$IMG_DISK" --hex "$DISK_HEX"

# --- 1. build the image (idempotent) + the ventium_soc --soc TB -----------------
say "1. build pide.bin + the ventium_soc --soc TB (with -DVEN_IDE_DISK_HEX)"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$IMG" ]] || { echo "FATAL: image $IMG missing"; exit 1; }
echo "image: $IMG ($(stat -c%s "$IMG") bytes); disk: $IMG_DISK ($(stat -c%s "$IMG_DISK") bytes)"
make -C "$REPO/verif/tb" soc VEN_IDE_DISK_HEX="$DISK_HEX" >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }
echo "soc TB: $SOC_TB"

# Capture the pristine disk md5 BEFORE any qemu run; M8.4b's WRITE SECTORS must
# NOT persist to the committed pide.img (snapshot=on routes writes to a temp
# overlay). The POST check after Stage 3 enforces it.
PRE_MD5="$(md5sum "$IMG_DISK" | cut -d' ' -f1)"

# --- 2. confirm the image reaches isa-debug-exit under qemu-system (WITH drive) -
say "2. confirm pide.bin runs to isa-debug-exit (code 133) under qemu-system-i386 + the IDE drive"
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing (run verif/sys/build-qemu-system.sh)"; exit 1; }
[[ -f "$IMG_DISK" ]] || { echo "FATAL: IDE disk image $IMG_DISK missing (Stage 0 failed)"; exit 1; }
set +e
timeout 30 "$QSYS" -display none -machine pc -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$IMG" $DRIVE >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "133" ]] || { echo "FATAL: image reached qemu exit $RC, expected 133 (drive missing -> IDENTIFY/READ abort?)"; exit 1; }
echo "qemu-system exit code = $RC (isa-debug-exit 0x42 -> (0x42<<1)|1 = 133): OK"

# --- 3. (re)generate the per-record golden (authoritative single-step oracle) ---
say "3. generate the per-record golden (gen_trace.py --system, qemu-system single-step, WITH the IDE drive)"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$IMG" --image-mode bios \
    --out "$GOLD_GEN" --port "$PORT" --max-insn "$MAXI" --args $DRIVE
echo "golden: $GOLD_GEN ($(wc -l < "$GOLD_GEN") lines)"

# drift check vs the committed reference golden (evidence artifact must not rot).
# Compare the trace RECORDS (line 2+), skipping line 1 (the `note` metadata),
# which legitimately records the invocation's -drive path (relative in the
# committed file vs the absolute path the gate passes) and is not part of the
# record stream the gate grades.
if [[ -f "$GOLD_REF" ]]; then
  if diff -q <(tail -n +2 "$GOLD_REF") <(tail -n +2 "$GOLD_GEN") >/dev/null 2>&1; then
    echo "golden drift check: records identical to committed $GOLD_REF: OK"
  else
    echo "NOTE: regenerated golden records differ from the committed reference"
    echo "      ($GOLD_REF) — qemu/host detail changed; the live oracle below is"
    echo "      authoritative. Inspect if unexpected."
  fi
fi

# snapshot guard: the committed pide.img must be byte-pristine after the qemu
# WRITE runs (Stage 2 + Stage 3). If it changed, snapshot=on is missing and the
# single-source invariant is broken.
POST_MD5="$(md5sum "$IMG_DISK" | cut -d' ' -f1)"
[[ "$POST_MD5" == "$PRE_MD5" ]] || { echo "FATAL: pide.img MUTATED by a differential WRITE ($PRE_MD5 -> $POST_MD5); is snapshot=on on the -drive?"; exit 1; }
echo "disk pristine check: pide.img md5 unchanged after the WRITE runs ($POST_MD5): OK"

# --- 4. run ventium_soc on pide.bin ---------------------------------------------
say "4. run ventium_soc on pide.bin (IDE/ATA primary master, PIO)"
"$SOC_TB" --image "$IMG" --out "$RTL_OUT" \
    --max-insn "$MAXI" --max-cycles 20000000 --quiesce 300
echo "RTL soc trace: $RTL_OUT ($(wc -l < "$RTL_OUT") lines)"

# --- 5. per-record differential -------------------------------------------------
say "5. per-record differential (compare.py --mode func): golden vs RTL"
set +e
"$PY" "$REPO/verif/diff/compare.py" --mode func "$GOLD_GEN" "$RTL_OUT"
CMP=$?
set -e

echo
if [[ "$CMP" == "0" ]]; then
  echo "SOC-IDE-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  IDE/ATA primary master PIO (reset signature + absent-slave masking +"
  echo "  IDENTIFY 256 words + READ SECTORS LBA 0/127 byte-identical to the"
  echo "  single-source disk + DIAGNOSTIC): byte-identical to qemu-system-i386"
  echo "  over all $(($(wc -l < "$RTL_OUT")-1)) retired instructions."
  echo
  echo "M8.4 SOC IDE GATE: EQUIVALENT (per-record, full differential)"
else
  echo "M8.4 SOC IDE GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
