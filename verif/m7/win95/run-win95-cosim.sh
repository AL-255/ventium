#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# M7.3b — Win95 system co-sim input-replay lock-step (docs/m7-lockstep-spec.md M7.3).
#
# qemu-system-i386 (under rr=replay) was the golden + ENVIRONMENT (the M7.3a
# producer); the Ventium RTL is the CHECKED CPU. The TB loads QEMU's initial
# PHYSICAL-memory image, cold-resets the core at F000:FFF0, drives the RTL through
# the golden instruction stream, REPLAYS the recorded device-read values (dev_in)
# at each IN the core issues on the io_* bus, and compare_stream.py grades ONLY the
# CPU architectural delta (sys mode). A divergence on a normal instruction would be
# a real CPU bug; an out-of-image fetch is an honest image-coverage bound.
#
#   bash verif/m7/win95/run-win95-cosim.sh [MAX_INSN]
#     MAX_INSN  retired-instruction cap (default 300000 = the producer prefix).
#
# Prereq: the producer artifacts (gitignored under build/m7/win95/). If absent,
# regenerate them per the M7.3a contract:
#   bash verif/m7/win95/record.sh           # rr=record -> replay.bin + overlay
#   python3 verif/qemu-trace/gen_trace.py --system-replay ... (see the contract)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="$REPO/build/m7/win95"
GOLDEN="$OUT/win95-boot.vtrace"
IMAGE="$OUT/win95-boot.image.json"
RTL="$OUT/win95-boot.rtl.sys.vtrace"
TB="$REPO/verif/tb/obj_dir/tb_ventium"
CMP="$REPO/verif/diff/compare_stream.py"
MAXI="${1:-300000}"
PY=/usr/bin/python3; command -v "$PY" >/dev/null || PY="$(command -v python3)"

[[ -f "$GOLDEN" ]] || { echo "missing golden: $GOLDEN (regen per M7.3a contract)"; exit 1; }
[[ -f "$IMAGE"  ]] || { echo "missing image:  $IMAGE  (regen per M7.3a contract)"; exit 1; }

echo "== 1. build the RTL TB =="
make -C "$REPO/verif/tb" rtl >/dev/null

echo "== 2. RTL co-sim run (cosim_en=1, system boot, IN/OUT replay) =="
"$TB" --win95-image "$IMAGE" --lockstep "$GOLDEN" --system \
      --out "$RTL" --max-insn "$MAXI" --quiesce 200 2>&1 | sed 's/^/   /'

echo "== 3. compare RTL vs golden (sys mode, streaming) — find bit-exact prefix =="
# --dedup-golden collapses the 8 exact full-record re-dumps qemu's one-insn-per-tb
# capture emits (mid-`rep movsb` / TB-boundary; provably artifacts — see the
# comparator's module doc), which are golden-only and otherwise mis-align the RTL's
# one-record-per-retirement stream. The field grading itself stays byte-strict.
set +e
"$PY" "$CMP" "$GOLDEN" "$RTL" --sys --dedup-golden 2>&1 | sed 's/^/   /'
FULL_RC=${PIPESTATUS[0]}
set -e

# Bisect the bit-exact prefix length the RTL reached (coarse powers-of-two probe;
# the full-stream line above is the authoritative bound).
echo "== 4. bit-exact prefix length (coarse probe) =="
LAST_OK=0
for N in 32 128 2560 20000 85000 200000 250000 300000; do
  if "$PY" "$CMP" "$GOLDEN" "$RTL" --sys --dedup-golden --max "$N" >/dev/null 2>&1; then LAST_OK=$N; else break; fi
done
echo "   RTL is bit-exact (EQUIVALENT) through at least the first $LAST_OK records."
echo "   (full-stream compare exit=$FULL_RC: 0=fully equivalent over the prefix,"
echo "    1=divergence at the reported record = the honest bound.)"
