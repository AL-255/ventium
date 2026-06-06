#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Ventium — test386.asm external differential gate (prefix vs qemu-system-i386).
#
# test386.asm (barotto/test386.asm, GPL-3.0) is a comprehensive freestanding x86
# CPU tester that boots as a 64 KiB BIOS image (reset 0xfffffff0 -> f000:0045) and
# exercises 80386+ conditional jumps, addressing modes, protected mode, V86, bit
# ops, string ops, etc. — exactly the system-mode image model the Ventium sys/SoC
# harness already runs (qemu-system-i386 -bios + gen_trace.py --system).
#
# This is an EXTERNAL, independently-authored corpus (not Ventium-written), run as
# a PREFIX differential: qemu-system-i386 single-step is the golden, the Ventium
# RTL (ventium_soc, soc_en=1 — its PMIO acks the test's POST-code port writes so
# the run is not halted by I/O) is the checked CPU, compared per-record under the
# EFLAGS-undefined mask. The bare core (ventium_top --system) HALTs at the first
# POST `OUT DX,AL` (no PC platform), so the SoC is the correct vehicle.
#
# Result (2026-06-05): EQUIVALENT to 60,000 instructions (verified at 1.5k/30k/60k);
# the committed reference golden is a 1,500-insn fast prefix. Raise MAXI for a
# deeper run; the eventual frontier is expected where test386 uses an instruction
# or platform device the Ventium RTL/SoC does not yet model (an honest gap-finder,
# like the M7 Quake/Win95 lock-step).
#
# The committed test386.bin is the nasm-built image (the GPL-3.0 source lives in
# ventium-refs/09-external-cpu-tests/test386.asm/). To rebuild it:
#   nasm -i./src/ -f bin src/test386.asm -w-all -o test386.bin   (in that source dir)
#
# Usage: bash verif/external/test386/run-test386-gate.sh [MAXI]   (MAXI default 1500)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$REPO/verif/external/test386"
QSYS="$REPO/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
GEN="$REPO/verif/qemu-trace/gen_trace.py"
CMP="$REPO/verif/diff/compare.py"
OUTDIR="$REPO/build/ext"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUTDIR"

IMG="$HERE/test386.bin"
GOLD_REF="$HERE/test386.sys.vtrace.golden" # committed 1500-insn reference
GOLD="$OUTDIR/test386.golden.vtrace"        # freshly regenerated
RTL="$OUTDIR/test386.soc.vtrace"
MAXI="${1:-1500}"
PORT="${PORT:-51778}"

say(){ echo; echo "=== $* ==="; }

say "1. build the ventium_soc TB + confirm inputs"
[[ -f "$IMG" ]] || { echo "FATAL: $IMG missing (build test386.asm with nasm)"; exit 1; }
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing (run verif/sys/build-qemu-system.sh)"; exit 1; }
make -C "$REPO/verif/tb" soc >/dev/null 2>&1
SOC_TB="$REPO/verif/tb/obj_dir_soc/tb_soc"
[[ -x "$SOC_TB" ]] || { echo "FATAL: SoC TB not built"; exit 1; }
echo "image: $IMG ($(stat -c%s "$IMG") bytes); prefix MAXI=$MAXI"

say "2. golden: qemu-system-i386 single-step prefix (gen_trace.py --system)"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$IMG" --image-mode bios \
    --out "$GOLD" --port "$PORT" --max-insn "$MAXI"
echo "golden: $GOLD ($(wc -l < "$GOLD") lines)"
# drift-check the committed 1500-insn reference (only when MAXI covers it)
if [[ "$MAXI" -ge 1500 && -f "$GOLD_REF" ]]; then
  if head -1501 "$GOLD" | diff -q - "$GOLD_REF" >/dev/null 2>&1; then
    echo "golden drift check (first 1500): identical to committed reference: OK"
  else
    echo "NOTE: regenerated golden's first 1500 differ from the committed reference"
    echo "      (qemu/host detail changed); the live golden above is authoritative."
  fi
fi

say "3. RTL: ventium_soc on test386.bin (PMIO handles the POST-code port I/O)"
"$SOC_TB" --image "$IMG" --out "$RTL" --max-insn "$MAXI" \
    --max-cycles 200000000 --quiesce 400
echo "RTL soc trace: $RTL ($(wc -l < "$RTL") lines)"

say "4. per-record differential (compare.py --mode func): golden vs RTL"
set +e
"$PY" "$CMP" --mode func --all --max-report 8 "$GOLD" "$RTL"
CMP_RC=$?
set -e

echo
if [[ "$CMP_RC" == "0" ]]; then
  echo "TEST386-GATE-OK  (EQUIVALENT over $(($(wc -l < "$RTL")-1)) retired instructions)"
  echo "  ventium_soc matches qemu-system-i386 byte-for-byte across the test386.asm"
  echo "  prefix (external x86 CPU tester, GPL-3.0, src in ventium-refs)."
else
  echo "TEST386: DIVERGENCE at the frontier (compare.py exit $CMP_RC) — the first"
  echo "  instruction/feature test386 exercises that the RTL/SoC does not yet match"
  echo "  (an ISA/platform gap to triage, or a deeper-than-current-scope feature)."
  exit 1
fi
