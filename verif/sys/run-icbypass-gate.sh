#!/usr/bin/env bash
# verif/sys/run-icbypass-gate.sh
# REVIEW1_Aug2 H-06 / REVIEW2_aug2 H-13: the non-allocating INSTRUCTION-FETCH bypass.
#
# H-13 MADE THIS THE DEFAULT, so the two sides of this comparison SWAPPED. The shipping
# build now honours CR0.CD; the CACHING build is the one that needs an opt-out define
# (VEN_IC_NO_FETCH_BYPASS). The gate compares default-vs-opt-out rather than
# default-vs-define, and its "must refetch MORE" direction is unchanged in meaning:
# the honouring build (now the default) must issue more reads than the ignoring one.
#
# ic_fill_nocache was tied to 0 because driving it from CR0.CD livelocks: the I-cache IS
# the fetch datapath, so a line that never validates is refetched forever (0 instructions
# in 8000 clocks). The bypass window lets the fetch read the just-filled line WITHOUT
# validating it, so the bytes are delivered and nothing is cached.
#
# A gate that only checked "it still runs" would be satisfied by a build that quietly
# kept caching. This asserts BOTH halves, which together are what "non-allocating" means:
#
#   1. IT REALLY DOES NOT CACHE. On images that REUSE instruction lines, the bypass build
#      must issue MORE bus reads than the caching build. Measured: psmm 48729 -> 118777
#      (2.4x), pv86 17248 -> 22336, pstk16 3044 -> 4580. 22 of 60 corpus images differ.
#      An image with no line reuse (pmode) is identical in both builds and proves
#      nothing -- which is exactly why this gate names reuse-heavy images explicitly.
#
#   2. IT IS ARCHITECTURALLY TRANSPARENT. The final state must be byte-identical to the
#      caching build. Refetching more is the POINT; computing something different is a bug.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TB="$ROOT/verif/tb"
DEF="$TB/obj_dir/tb_ventium"
# NOTE the naming: DEF is now the BYPASSING (CD-honouring) build, and CCH is the
# CACHING one built with the opt-out. The variables keep their old roles -- BYP is
# whichever build bypasses -- so the comparison logic below is untouched.
CCH_OBJ=obj_dir_iccache
CCH="$TB/$CCH_OBJ/tb_ventium"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

echo "=== build the CACHING (opt-out) object dir; the DEFAULT now bypasses ==="
make -s -C "$TB" rtl OBJDIR="$CCH_OBJ" VL_EXTRA_DEFINES="+define+VEN_IC_NO_FETCH_BYPASS" >/dev/null
[ -x "$CCH" ] || { echo "ICBYPASS-GATE-FAIL (caching TB not built)"; exit 1; }
[ -x "$DEF" ] || { make -s -C "$TB" rtl OBJDIR=obj_dir >/dev/null; }
# The roles: the CACHING build is the baseline, the DEFAULT build is the bypassing one.
BYP="$DEF"
DEF="$CCH"

run() { timeout 120 "$1" --system --image "$2" --out "$3" --max-insn 3000 --quiesce 1500 2>&1; }

# reuse-heavy images: a real bypass MUST refetch more on these.
REUSE="psmm pv86 pstk16 ptaskv86 pssiret"
fail=0

echo
echo "=== 1. the bypass must actually REFETCH (it must not be caching) ==="
for t in $REUSE; do
  IMG="$ROOT/verif/sys/tests/$t/$t.bin"; [ -f "$IMG" ] || continue
  A="$(run "$DEF" "$IMG" /dev/null | grep -oE 'bus: [0-9]+ reads' | grep -oE '[0-9]+')"
  B="$(run "$BYP" "$IMG" /dev/null | grep -oE 'bus: [0-9]+ reads' | grep -oE '[0-9]+')"
  if [ -z "$A" ] || [ -z "$B" ]; then echo "  FAIL $t: no bus count (did it hang?)"; fail=1; continue; fi
  if [ "$B" -le "$A" ]; then
    echo "  FAIL $t: bypass reads $B <= caching reads $A -- the bypass is still caching,"
    echo "       so a stale executable line can be hit after CD is set."
    fail=1
  else
    echo "  ok   $t: $A -> $B reads (+$((B-A)); refetching, not caching)"
  fi
done

echo
echo "=== 2. and it must be ARCHITECTURALLY TRANSPARENT ==="
for t in $REUSE ppage pxpage pintr16 pdebug pcpl; do
  IMG="$ROOT/verif/sys/tests/$t/$t.bin"; [ -f "$IMG" ] || continue
  run "$DEF" "$IMG" "$W/a.vt" >/dev/null; run "$BYP" "$IMG" "$W/b.vt" >/dev/null
  A="$(tail -1 "$W/a.vt" 2>/dev/null)"; B="$(tail -1 "$W/b.vt" 2>/dev/null)"
  if [ -z "$A" ] || [ "x$A" != "x$B" ]; then
    echo "  FAIL $t: final architectural state DIFFERS from the caching build"
    fail=1
  else
    echo "  ok   $t: final state identical"
  fi
done

[ "$fail" = 0 ] || { echo; echo "ICBYPASS-GATE-FAIL"; exit 1; }
echo
echo "ICBYPASS-GATE-OK (fetch bypass refetches instead of caching, and changes nothing architecturally)"
