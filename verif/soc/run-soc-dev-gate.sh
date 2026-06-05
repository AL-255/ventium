#!/usr/bin/env bash
# Ventium M8.2 — SoC PC-PERIPHERAL device gate (RTC + 8042 + port-92 + A20 mask).
#
# FULL PER-RECORD DIFFERENTIAL — stronger than the M8.1 pirqsoc checkpoint gate.
# Unlike pirqsoc (whose async IRQ delivery is invisible to qemu's single-step
# oracle, forcing a checkpoint-differential), psocdev is entirely SYNCHRONOUS
# (IN/OUT + A20-masked memory accesses, NO interrupts), so the standard
# gen_trace.py --system single-step golden is a valid PER-RECORD oracle and the
# gate is plain compare.py EQUIVALENT — like the verify-sys tests, but on
# ventium_soc (with the M8.2 devices) instead of ventium_top.
#
# What it proves, byte-identical to qemu-system-i386 8.2.2 over every retired
# instruction:
#   * MC146818 RTC : REG_D (VRT=0x80), REG_B control round-trip, a scratch CMOS
#     byte (index 0x50) round-trip, the index-port read (=0xFF), the NMI-disable
#     bit non-aliasing — all TIME-INVARIANT (no host-clock-derived state read).
#   * port-92      : the outport read/write (A20 bit1; bit0 kept 0 = no reset).
#   * 8042         : the queue-independent A20 commands 0xDF/0xDD, observed
#     through the A20 mask (the OBF/data read path is an explicit oracle
#     boundary — qemu attaches a live PS/2 keyboard whose async power-on bytes a
#     controller-only model cannot reproduce — covered by the unit self-check).
#   * A20 mask     : the cross-device 1 MiB wraparound (A20_HI = A20_LO+(1<<20)
#     aliases under A20-masked, distinct under A20-enabled), value-exact vs qemu
#     (dcache_timing carries no data, so masked loads return via mem_rdata for
#     the wrapped address exactly as qemu does).
#
# Never weakens / never fakes a sys-diff. Usage: bash verif/soc/run-soc-dev-gate.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$REPO/verif/sys/tests/psocdev"
OUTDIR="$REPO/build/soc"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

IMG="$TDIR/psocdev.bin"
GOLD_REF="$TDIR/psocdev.sys.vtrace.golden"     # committed reference (evidence)
GOLD_GEN="$OUTDIR/psocdev.sys.vtrace.golden"   # freshly regenerated this run
RTL_OUT="$OUTDIR/psocdev.rtl.soc.vtrace"
PORT="${PORT:-51124}"
MAXI=250

say(){ echo; echo "=== $* ==="; }

# --- 1. build the image (idempotent) + the ventium_soc --soc TB -----------------
say "1. build psocdev.bin + the ventium_soc --soc TB"
make -C "$TDIR" >/dev/null 2>&1 || true
[[ -f "$IMG" ]] || { echo "FATAL: image $IMG missing"; exit 1; }
echo "image: $IMG ($(stat -c%s "$IMG") bytes)"
make -C "$REPO/verif/tb" soc >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB $SOC_TB not built"; exit 1; }
echo "soc TB: $SOC_TB"

# --- 2. confirm the image reaches isa-debug-exit under qemu-system --------------
say "2. confirm psocdev.bin runs to isa-debug-exit (code 133) under qemu-system-i386"
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing (run verif/sys/build-qemu-system.sh)"; exit 1; }
set +e
timeout 20 "$QSYS" -display none -machine pc -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$IMG" >/dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "133" ]] || { echo "FATAL: image reached qemu exit $RC, expected 133"; exit 1; }
echo "qemu-system exit code = $RC (isa-debug-exit 0x42 -> (0x42<<1)|1 = 133): OK"

# --- 3. (re)generate the per-record golden (authoritative single-step oracle) ---
say "3. generate the per-record golden (gen_trace.py --system, qemu-system single-step)"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$IMG" --image-mode bios \
    --out "$GOLD_GEN" --port "$PORT" --max-insn "$MAXI"
echo "golden: $GOLD_GEN ($(wc -l < "$GOLD_GEN") lines)"

# drift check vs the committed reference golden (evidence artifact must not rot)
if [[ -f "$GOLD_REF" ]]; then
  if diff -q "$GOLD_REF" "$GOLD_GEN" >/dev/null 2>&1; then
    echo "golden drift check: identical to committed $GOLD_REF: OK"
  else
    echo "NOTE: regenerated golden differs from the committed reference"
    echo "      ($GOLD_REF) — qemu/host detail changed; the live oracle below is"
    echo "      authoritative. Inspect if unexpected."
  fi
fi

# --- 4. run ventium_soc on psocdev.bin ------------------------------------------
say "4. run ventium_soc on psocdev.bin (RTC + 8042 + port-92 + A20 mask)"
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
  echo "SOC-DEV-GATE-OK  (PER-RECORD DIFFERENTIAL EQUIVALENT)"
  echo "  RTC (REG_D/REG_B/scratch/index-read/NMI-bit) + port-92 (A20 reg) +"
  echo "  8042 A20 commands + the cross-device A20 wraparound mask: byte-identical"
  echo "  to qemu-system-i386 over all $(($(wc -l < "$RTL_OUT")-1)) retired instructions."
  echo
  echo "M8.2 SOC DEVICE GATE: EQUIVALENT (per-record, full differential)"
else
  echo "M8.2 SOC DEVICE GATE: FAIL (compare.py exit $CMP)"
  exit 1
fi
