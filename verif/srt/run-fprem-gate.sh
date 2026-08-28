#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-fprem-gate.sh — FPREM/FPREM1 differential gate across every remainder-
# engine configuration. The corpus program tx_fprem (verif/tests/tx_fprem/,
# auto-discovered by `make verify` for the canonical build) is additionally
# diffed against the SAME pinned-QEMU golden on:
#
#   canonical  verif/tb/obj_dir/tb_ventium        dedicated fpu_fprem engine
#   srt        obj_dir_fprem_srt (+VEN_SRT_ITER +VEN_FPREM)
#                                               remainder folded into the
#                                               unified divide/sqrt engine
#   kvfull     obj_dir_l1axi_kvf (make l1axi_kv_full, the deployed define set:
#                                               unified engine + FP pipes +
#                                               L1/AXI bus mode; run --l1-axi)
#
# The golden is QEMU -cpu pentium, which models FPREM/FPREM1 (values, C2
# partial reduction, FPREM quotient CCs) exactly. ONE documented oracle gap is
# masked: QEMU's FPREM1 never fills C0/C3/C1 (its SoftFloat call drops the
# quotient out-pointer), while the RTL reports the architectural round-nearest
# Q2/Q1/Q0 -- the mask (0x4300) and its record ranges come from the test's
# manifest.json, so this script and `make verify` cannot drift apart.
#
# Prints FPREM-GATE-OK on success.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TB="$ROOT/verif/tb"
T="$ROOT/verif/tests/tx_fprem"
REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
QEMU="$REFS/build/qemu/build/qemu-i386"
OUT="$ROOT/build/fprem"
PORT="${FPREM_GATE_PORT:-26310}"
mkdir -p "$OUT"

[ -x "$QEMU" ] || { echo "FPREM-GATE-FAIL: pinned qemu-i386 missing: $QEMU"; exit 1; }

echo "== FPREM/FPREM1 gate: build the tx_fprem image =="
CC="${CC:-gcc}"
"$CC" -m32 -march=pentium -nostdlib -static -Wl,--build-id=none \
    -Wl,-Ttext=0x08048000 -o "$OUT/tx_fprem.elf" "$T/tx_fprem.s"
python3 "$REFS/tools/isa_verify.py" "$OUT/tx_fprem.elf" >/dev/null
python3 "$ROOT/verif/tests/elf2flat.py" "$OUT/tx_fprem.elf" \
    --out "$OUT/tx_fprem.flat" --base 0x08048000 >/dev/null

echo "== FPREM/FPREM1 gate: golden (pinned QEMU gdbstub, --x87) =="
MAX="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["max_insn"])' "$T/manifest.json")"
python3 "$ROOT/verif/qemu-trace/gen_trace.py" --qemu "$QEMU" --elf "$OUT/tx_fprem.elf" \
    --out "$OUT/tx_fprem.golden.vtrace" --max-insn "$MAX" --x87 --port "$PORT" >/dev/null
INIT_ESP="$(python3 - "$OUT/tx_fprem.golden.vtrace" <<'PYEOF'
import sys, json
f = open(sys.argv[1]); f.readline(); print(json.loads(f.readline())["esp"])
PYEOF
)"

# The FPREM1 quotient-CC oracle-gap mask, derived from the LIVE manifest (the
# same snippet the corpus worker uses, so the two cannot drift).
MSK="$(python3 - "$T/manifest.json" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
cc = m.get("x87_fprem1_cc_ranges")
def fmt(r):
    s = f"{r[0]}:{'' if len(r) < 2 or r[1] is None else r[1]}"
    if len(r) >= 3 and r[2]:
        s += f"={r[2]}"
    return s
args = []
if cc:
    args.append("--mask-fstat-exc 0x4300")
    args += [f"--mask-fstat-range {fmt(r)}" for r in cc]
print(" ".join(args))
PYEOF
)"

fail=0
run_cmp () {  # <label> <tb binary> <extra tb flags...>
  local label="$1" bin="$2"; shift 2
  "$bin" --image "$OUT/tx_fprem.flat" --load 0x08048000 --entry 0x08048000 \
      --init-esp "$INIT_ESP" --out "$OUT/tx_fprem.$label.vtrace" \
      --max-insn "$MAX" --x87 "$@" > "$OUT/$label.log" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "  $label: tb_ventium run failed (exit $rc; see $OUT/$label.log)"; fail=1; return
  fi
  if python3 "$ROOT/verif/diff/compare.py" --mode func $MSK \
      "$OUT/tx_fprem.golden.vtrace" "$OUT/tx_fprem.$label.vtrace" \
      > "$OUT/$label.cmp" 2>&1; then
    echo "  $label: EQUIVALENT ($(grep -o '[0-9]* records match' "$OUT/$label.cmp"))"
  else
    echo "  $label: DIVERGENT:"; tail -4 "$OUT/$label.cmp" | sed 's/^/    /'; fail=1
  fi
}

echo "== canonical build (dedicated fpu_fprem engine) =="
make -C "$TB" OBJDIR=obj_dir >/dev/null
run_cmp canon "$TB/obj_dir/tb_ventium"

echo "== unified-engine build (+VEN_SRT_ITER +VEN_FPREM) =="
make -C "$TB" rtl OBJDIR=obj_dir_fprem_srt \
    VL_EXTRA_DEFINES='+define+VEN_SRT_ITER +define+VEN_FPREM' >/dev/null
# The unified engine spends multiple clocks per remainder step, so one partial
# pass can idle longer than the TB's default quiesce; raise it (the canonical
# run above stays at the default on purpose -- the corpus gate uses that).
run_cmp srt "$TB/obj_dir_fprem_srt/tb_ventium" --quiesce 200000

echo "== deployed-profile build (l1axi_kv_full: unified engine, L1/AXI) =="
make -C "$TB" l1axi_kv_full >/dev/null
# A multi-cycle mode-2 access can go many clocks without retiring, so this run
# needs the raised idle threshold the L1/AXI gates use.
run_cmp kvfull "$TB/obj_dir_l1axi_kvf/tb_ventium" --l1-axi --quiesce 200000

if [ "$fail" = 0 ]; then
  echo "FPREM-GATE-OK"
  exit 0
fi
echo "FPREM-GATE-FAIL"
exit 1
