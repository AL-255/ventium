#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# =============================================================================
# run_x87_boundary.sh -- standalone gate for the x87 DEFERRED-OP boundary test
# (REVIEW_Jun5.md Recommended Step 4 + Limit #2). DEDICATED run glue so it does
# NOT touch any shared Makefile or the central verify.sh corpus discovery.
#
# It pins the machine-checkable claim that a DEFERRED x87 op (transcendental /
# BCD / FP-environment family, m3-fpu-spec.md "DEFERRED -- loud HALT, never
# fake") makes the RTL core enter S_HALT (d_unknown -> S_DECODE default ->
# S_HALT) and STOP RETIRING at the deferred op -- never silently mis-executing
# it and never retiring anything after it.
#
# This is intentionally NOT run through compare.py vs a QEMU golden: QEMU (a full
# x87 implementation) DOES execute FSIN with its own softfloat approximation and
# keeps running, so a differential compare would see a length mismatch. The
# *correct* boundary behavior is exactly that divergence -- RTL halts where QEMU
# continues -- so we assert the HALT on the RTL trace DIRECTLY instead.
#
# Test program: verif/tests/tx_deferred_halt/tx_deferred_halt.s
#   mov $0xdead0001,%eax   ; PRE  sentinel -- MUST retire (boundary reached)
#   fldpi                  ; load a normal operand -- MUST retire
#   fsin   (D9 FE)         ; DEFERRED transcendental -- RTL MUST HALT here
#   mov $0xdead0002,%ebx   ; POST sentinel -- MUST NOT retire
#   mov $1,%eax; xor %ebx; int $0x80   ; clean exit -- MUST NOT be reached
#
# PASS criteria (all must hold against the RTL func trace):
#   1. the PRE sentinel retired   (a record with eax == 0xdead0001 exists), AND
#      fldpi retired              (a record at pc == <fsin_pc - 2> exists);
#   2. the deferred op NEVER retired (no record at pc >= the fsin pc), AND
#   3. the POST sentinel NEVER retired (no record with ebx == 0xdead0002), AND
#   4. the core stopped via HALT/quiescence (tb did NOT stop on --max-insn, i.e.
#      it never ran the whole program -- it stalled at the deferred op).
#
# Touches ONLY verif/tests/tx_deferred_halt/* and verif/tests/build/. Reuses the
# orchestrator-built tb_ventium ($TB_BIN); it does NOT invoke verilator.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # verif/tests
ROOT="$(cd "$HERE/.." && pwd)"                            # verif
ROOT="$(cd "$ROOT/.." && pwd)"                            # repo root

TESTDIR="$HERE/tx_deferred_halt"
MANIFEST="$TESTDIR/halt/manifest.json"
SRC="$TESTDIR/tx_deferred_halt.s"

PYTHON="${PYTHON:-python3}"
CC="${CC:-gcc}"
CFLAGS_BASE="${CFLAGS_BASE:--m32 -march=pentium -nostdlib -static -Wl,--build-id=none}"
ELF2FLAT="${ELF2FLAT:-$ROOT/verif/tests/elf2flat.py}"
ISA_VERIFY="${ISA_VERIFY:-$ROOT/ventium-refs/07-p5-emulation-harness/tools/isa_verify.py}"
TB_BIN="${TB_BIN:-$ROOT/verif/tb/obj_dir/tb_ventium}"

WORK="$ROOT/build/x87-boundary"
mkdir -p "$WORK"

ELF="$WORK/tx_deferred_halt.elf"
FLAT="$WORK/tx_deferred_halt.flat"
RTL="$WORK/tx_deferred_halt_rtl.vtrace"

die()  { printf '\nrun_x87_boundary: FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '    %s\n' "$*"; }

# ---- preflight -------------------------------------------------------------
[ -f "$SRC" ]        || die "test source missing: $SRC"
[ -f "$MANIFEST" ]   || die "manifest missing: $MANIFEST"
[ -f "$ELF2FLAT" ]   || die "elf2flat.py missing: $ELF2FLAT"
[ -x "$TB_BIN" ]     || die "tb_ventium not built (orchestrator builds it): $TB_BIN"
command -v "$CC" >/dev/null 2>&1 || die "C compiler not found: $CC"

# ---- manifest fields -------------------------------------------------------
read -r LOAD ENTRY MAX PRE_EAX POST_EBX < <("$PYTHON" - "$MANIFEST" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))
print(m.get("load_addr","0x08048000"), m.get("entry","0x08048000"),
      m.get("max_insn",16),
      str(m.get("pre_marker_eax","0xdead0001")).lower(),
      str(m.get("post_marker_ebx","0xdead0002")).lower())
PY
)
info "test       : tx_deferred_halt (deferred x87 op -> loud HALT)"
info "deferred op : FSIN (D9 FE), transcendental (m3-fpu-spec.md DEFERRED set)"
info "load/entry  : $LOAD / $ENTRY   max-insn: $MAX"
info "PRE  marker : eax=$PRE_EAX     POST marker: ebx=$POST_EBX"

echo "=== [1/4] build ELF (gcc -m32 -march=pentium) ==="
"$CC" $CFLAGS_BASE -Wl,-Ttext="$LOAD" -o "$ELF" "$SRC" \
    > "$WORK/build.log" 2>&1 || { sed 's/^/    /' "$WORK/build.log"; die "gcc build failed"; }

if [ -f "$ISA_VERIFY" ]; then
    "$PYTHON" "$ISA_VERIFY" "$ELF" > "$WORK/isa.log" 2>&1 \
        || die "isa_verify rejected the ELF (non-P5 ISA?) -- see $WORK/isa.log"
fi

echo "=== [2/4] flatten (elf2flat.py) ==="
"$PYTHON" "$ELF2FLAT" "$ELF" --out "$FLAT" --base "$LOAD" \
    > "$WORK/flat.log" 2>&1 || { sed 's/^/    /' "$WORK/flat.log"; die "elf2flat failed"; }

# Address of the deferred op (FSIN). It is the byte right after the 2-byte fldpi
# (D9 EB), which follows the 5-byte `mov imm32,%eax`. Derive it from the symbol
# table + objdump so the check is robust if the program shifts; fall back to the
# computed offset (load + 7).
FSIN_PC="$("$PYTHON" - "$ELF" "$LOAD" <<'PY'
import sys, subprocess, re
elf, load = sys.argv[1], int(sys.argv[2], 16)
try:
    out = subprocess.check_output(["objdump","-d","--no-show-raw-insn",elf],
                                  text=True)
    for line in out.splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+(fsin)\b", line)
        if m:
            print("0x%08x" % int(m.group(1), 16)); break
    else:
        print("0x%08x" % (load + 7))
except Exception:
    print("0x%08x" % (load + 7))
PY
)"
FLDPI_PC="$(printf '0x%08x' $(( FSIN_PC - 2 )))"
info "fldpi pc    : $FLDPI_PC  (last op that MUST retire)"
info "fsin  pc    : $FSIN_PC  (deferred op -- MUST NOT retire; HALT here)"

echo "=== [3/4] run tb_ventium on the RTL (--x87) ==="
# init ESP: the spec default loader value (no QEMU golden is consulted -- this
# test is RTL-only by design). tb_ventium accepts --init-esp.
"$TB_BIN" --image "$FLAT" --load "$LOAD" --entry "$ENTRY" \
    --init-esp 0x40c34910 --x87 --out "$RTL" --max-insn "$MAX" \
    > "$WORK/rtl.log" 2>&1 \
    || { sed 's/^/    /' "$WORK/rtl.log"; die "tb_ventium run failed"; }

echo "=== [4/4] assert the loud HALT boundary ==="
# Parse the RTL func trace and enforce the four PASS criteria.
"$PYTHON" - "$RTL" "$WORK/rtl.log" "$FSIN_PC" "$FLDPI_PC" "$PRE_EAX" "$POST_EBX" <<'PY' || exit 1
import sys, json

rtl, log, fsin_pc, fldpi_pc, pre_eax, post_ebx = sys.argv[1:7]
fsin  = int(fsin_pc, 16)
fldpi = int(fldpi_pc, 16)
pre   = int(pre_eax, 16)
post  = int(post_ebx, 16)

recs = []
with open(rtl) as f:
    f.readline()                       # skip the header line
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            recs.append(json.loads(line))
        except Exception:
            pass

def h(v):
    return int(str(v), 16) if isinstance(v, str) else int(v)

pcs       = [h(r["pc"]) for r in recs if "pc" in r]
saw_pre   = any("eax" in r and h(r["eax"]) == pre  for r in recs)
saw_fldpi = any(p == fldpi for p in pcs)
saw_fsin  = any(p == fsin  for p in pcs)
saw_after = any(p >= fsin  for p in pcs)        # deferred op OR anything past it
saw_post  = any("ebx" in r and h(r["ebx"]) == post for r in recs)

# Did tb stop because it ran the whole program (max-insn), or because the core
# HALTed / went quiescent? A quiescent / hung stop is the boundary we want;
# hitting --max-insn would mean the deferred op was (wrongly) executed.
with open(log) as f:
    logtxt = f.read()
stopped_on_maxinsn = "reached --max-insn" in logtxt
stopped_quiescent  = ("quiescent" in logtxt) or ("CPU HUNG" in logtxt)

print(f"    retired records : {len(recs)}")
print(f"    PRE sentinel (eax={pre_eax}) retired : {saw_pre}")
print(f"    fldpi (pc={fldpi_pc}) retired        : {saw_fldpi}")
print(f"    deferred fsin (pc={fsin_pc}) retired : {saw_fsin}")
print(f"    any record at/after fsin pc          : {saw_after}")
print(f"    POST sentinel (ebx={post_ebx}) retired: {saw_post}")
print(f"    tb stop: max-insn={stopped_on_maxinsn} quiescent/hung={stopped_quiescent}")

fails = []
if not saw_pre:    fails.append("PRE sentinel never retired (boundary not reached / mis-built)")
if not saw_fldpi:  fails.append("fldpi (the op before the deferred op) never retired")
if saw_fsin:       fails.append("DEFERRED op FSIN RETIRED -- it must HALT, not execute")
if saw_after:      fails.append("a record at/after the deferred op pc exists -- core did not HALT")
if saw_post:       fails.append("POST sentinel retired -- core ran past the deferred op")
if stopped_on_maxinsn:
    fails.append("tb stopped on --max-insn -- core kept retiring past the boundary")
if not stopped_quiescent:
    fails.append("tb did not report a quiescent/hung stop -- HALT not observed")

if fails:
    print("\nrun_x87_boundary: FAIL:")
    for x in fails:
        print("    - " + x)
    sys.exit(1)

print("\n    OK: deferred FSIN loud-HALTed at the boundary; nothing past it retired.")
sys.exit(0)
PY

echo "=== run_x87_boundary.sh: PASS (x87 deferred-op boundary pinned) ==="
