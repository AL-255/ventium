#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-pintslim-gate.sh — cross-privilege interrupt-frame stack-limit gate.
#
# pintslim (verif/sys/tests/pintslim/, see its manifest.json) proves the
# S_INT_PROBE frame pre-probe checks each frame slot with the SLOT'S width:
# a cross-privilege interrupt frame whose FIRST push slot ends exactly at the
# new stack segment's bound is legal in both frame widths (16-bit gate word
# slots, 32-bit gate dword slots), both stack B bits, and expand-up +
# expand-down forms, while one slot-width past the bound raises
# #SS(staged-SS-selector) (software INT: EXT=0)
# pre-commit (zero frame bytes). The segment-extent check is live only in
# the +VEN_SEG_ENFORCE variant build, so the discrimination is graded per
# build (the psmmmeta pattern):
#
#   canonical build : also a full differential vs the QEMU golden (QEMU does
#                     not limit-check frame pushes, so every case delivers);
#                     witnesses: all 16 cases delivered, zero faults.
#   +VEN_SEG_ENFORCE: the 8 at-bound cases deliver, the 8 one-past cases
#                     raise #SS(staged-SS-selector) pre-commit; +ven_faultlog
#                     must show two each of err=0x40/0x48/0x50/0x58.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
SYS="$ROOT/verif/sys"
REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
QSYS="$REFS/build/qemu/build-sys/qemu-system-i386"
GEN="$ROOT/verif/qemu-trace/gen_trace.py"
COMPARE="$ROOT/verif/diff/compare.py"
T="$SYS/tests/pintslim"
TB="$ROOT/verif/tb/obj_dir/tb_ventium"
TB_SEG="$ROOT/verif/tb/obj_dir_pintslim/tb_ventium"
OUT="$ROOT/build/sys"
PORT="${PORT:-41297}"
PY=/usr/bin/python3
command -v "$PY" >/dev/null || PY="$(command -v python3)"
mkdir -p "$OUT"

echo "== pintslim gate: interrupt-frame stack limit, both widths and forms =="

# --- 1. qemu-system-i386 (idempotent) + the image + both RTL testbenches ------
bash "$SYS/build-qemu-system.sh" >/dev/null
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing"; exit 1; }
make -C "$T" >/dev/null
make -C "$ROOT/verif/tb" rtl >/dev/null 2>&1
[[ -x "$TB" ]] || { echo "FATAL: RTL TB $TB not built"; exit 1; }
# The +VEN_SEG_ENFORCE variant: the segment-limit discrimination only exists
# when the checks are live. Separate obj dir (never the canonical
# obj_dir/tb_ventium).
make -C "$ROOT/verif/tb" rtl OBJDIR=obj_dir_pintslim \
    VL_EXTRA_DEFINES='+define+VEN_SEG_ENFORCE' >/dev/null 2>&1
[[ -x "$TB_SEG" ]] || { echo "FATAL: VEN_SEG_ENFORCE TB $TB_SEG not built"; exit 1; }

# --- 2. the image runs to the isa-debug-exit under free-running qemu ----------
set +e
timeout 20 "$QSYS" -display none -machine pc -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$T/pintslim.bin" >/dev/null 2>&1
RC=$?
set -e
echo "  qemu free-run pintslim.bin: exit $RC (expected 133)"
[[ "$RC" == "133" ]] || { echo "PINTSLIM-GATE-FAIL (pintslim.bin did not reach the isa-debug-exit)"; exit 1; }

# --- 3. canonical build: differential vs the QEMU golden + all-delivered ------
GOLD="$OUT/pintslim.sys.vtrace"
"$PY" "$GEN" --qemu "$QSYS" --system --image "$T/pintslim.bin" \
    --image-mode bios --out "$GOLD" --port "$PORT" --max-insn 8000
echo "  golden: $GOLD ($(wc -l < "$GOLD") lines)"

RTL_OUT="$OUT/pintslim.rtl.sys.vtrace"
FLOG="$OUT/pintslim.faultlog"
"$TB" --system --cosim --image "$T/pintslim.bin" --out "$RTL_OUT" \
    --max-insn 8000 --quiesce 800 +ven_faultlog >"$FLOG" 2>&1 || true
echo "  RTL trace: $RTL_OUT ($(wc -l < "$RTL_OUT") lines)"

set +e
RDIFF_OUT="$("$PY" "$COMPARE" --mode func --all --max-report 8 "$GOLD" "$RTL_OUT" 2>/dev/null)"
RDIFF_RC=$?
set -e
echo "$RDIFF_OUT" | sed 's/^/  /'
[[ "$RDIFF_RC" == "0" ]] || { echo "PINTSLIM-GATE-FAIL (canonical build DIVERGENT vs golden)"; exit 1; }
echo "  canonical: RTL system trace EQUIVALENT to the golden"

NFAULT="$(grep -c 'vec=' "$FLOG" || true)"
echo "  canonical fault log: $NFAULT fault(s) (want 0 -- the limit check is inert)"
[[ "$NFAULT" == "0" ]] || { echo "PINTSLIM-GATE-FAIL (canonical build faulted; see $FLOG)"; exit 1; }

python3 - "$RTL_OUT" <<'PYEOF'
import sys, json
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith('{"vtrace"')]
last = recs[-1]
H = lambda k: int(last[k], 16)
assert H("edi") == 0x42,       f"edi={last['edi']} != 0x42 (an in-image self-check failed -- see the fail code)"
assert H("ebx") == 0x000F5555, f"ebx={last['ebx']} != 0x000F5555 (AT_OK: an at-bound case did not deliver, or an IRETW R-case failed)"
assert H("esi") == 0,          f"esi={last['esi']} != 0 (SS_SEEN: the canonical build raised #SS -- the check is supposed to be inert)"
assert H("ecx") == 0,          f"ecx={last['ecx']} != 0 (SENTINEL: a #SS'd frame still wrote bytes)"
assert H("ebp") == 0xAAAA,     f"ebp={last['ebp']} != 0xAAAA (PAST_DLVR: a one-past case did not deliver)"
assert H("edx") >> 16 == 0x600D, f"edx={last['edx']} != 0x600D.... (pass magic)"
print(f"  canonical final record: edi=0x42 ebx=0xF5555 esi=0 ecx=0 ebp=0xAAAA ({len(recs)} records)")
PYEOF

# --- 4. +VEN_SEG_ENFORCE build: 8 deliver, 8 #SS(selector) pre-commit ----------
SEG_OUT="$OUT/pintslim.rtl.seg.vtrace"
SEG_FLOG="$OUT/pintslim.seg.faultlog"
"$TB_SEG" --system --image "$T/pintslim.bin" --out "$SEG_OUT" \
    --max-insn 8000 --quiesce 800 +ven_faultlog >"$SEG_FLOG" 2>&1 || true
echo "  RTL trace (+VEN_SEG_ENFORCE): $SEG_OUT ($(wc -l < "$SEG_OUT") lines)"

python3 - "$SEG_OUT" <<'PYEOF'
import sys, json
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith('{"vtrace"')]
last = recs[-1]
H = lambda k: int(last[k], 16)
assert H("edi") == 0x42,       f"edi={last['edi']} != 0x42 (an in-image self-check failed -- see the fail code)"
assert H("ebx") == 0x000F5555, f"ebx={last['ebx']} != 0x000F5555 (AT_OK: an at-bound case was rejected (the word-slot-as-dword defect) or an IRETW R-case false-#SS'd)"
assert H("esi") == 0xAAAA,     f"esi={last['esi']} != 0xAAAA (SS_SEEN: a one-past case did not #SS)"
assert H("ecx") == 0xAAAA,     f"ecx={last['ecx']} != 0xAAAA (SENTINEL: a #SS'd case wrote frame bytes -- the fault was not pre-commit)"
assert H("ebp") == 0,          f"ebp={last['ebp']} != 0 (PAST_DLVR: a one-past case DELIVERED under enforcement)"
assert H("edx") >> 16 == 0x600D, f"edx={last['edx']} != 0x600D.... (pass magic)"
print(f"  +VEN_SEG_ENFORCE final record: edi=0x42 ebx=0xF5555 esi=0xAAAA ecx=0xAAAA ebp=0 ({len(recs)} records)")
PYEOF

TOT="$(grep -c 'vec=' "$SEG_FLOG" || true)"
for SEL in 40 48 50 58; do
  COUNT="$(grep -c "vec=12 err=000000$SEL " "$SEG_FLOG" || true)"
  echo "  +VEN_SEG_ENFORCE #SS(0x$SEL): $COUNT (want 2)"
  [[ "$COUNT" == "2" ]] || { echo "PINTSLIM-GATE-FAIL (wrong #SS selector 0x$SEL; see $SEG_FLOG)"; exit 1; }
done
[[ "$TOT" == "8" ]] || { echo "PINTSLIM-GATE-FAIL (unexpected other faults; see $SEG_FLOG)"; exit 1; }

echo "PINTSLIM-GATE-OK"
