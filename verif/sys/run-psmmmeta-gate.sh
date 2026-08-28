#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# run-psmmmeta-gate.sh — SMM/RSM hidden-metadata restore gate.
#
# psmmmeta (verif/sys/tests/psmmmeta/, see its manifest.json) proves that RSM
# restores the interrupted context's hidden segment metadata — seg_pm_loaded[]
# provenance, seg_b[] D/B bits, ss_b stack width — with the PRE-SMI values
# shadowed at SMI entry, not the SMM handler's. Five SMI rounds in one image:
#   case A  never-reloaded DS/SS provenance, pre/post push equality
#   case B  16-bit mainline SS vs the handler's 32-bit load
#   case C  32-bit mainline SS vs the handler's 16-bit load
#   case D  data-segment D/B (seg_b[DS]): an expand-down DS, limit 0x0FFF,
#           makes an access at 0x10000 legal for B=1 and a #GP for B=0.
#           Both polarities (mainline B=1/handler B=0 and the reverse), and
#           the post-RSM legality must equal the pre-SMI legality. This is
#           the only consumer of seg_b[DS] and needs limit enforcement, so
#           it discriminates only on the +VEN_SEG_ENFORCE variant build; on
#           the canonical build it degrades to vacuous equality (documented
#           in manifest.json). The image self-calibrates with an ES probe:
#           when enforcement is detected, case A's high-ESP stack probes
#           would #SS against the unreloaded SS's 64K real-mode limit, so
#           case A drops ESP below 64K (forms coincide; equality holds).
#
# WITNESS-graded, no differential: the qemu-system gdbstub single-step path
# masks SMI and has no SMM awareness (the psmm oracle infeasibility), so
# grading is the RTL final-record witnesses + the QEMU free-run exit status
# (the image runs to the isa-debug-exit under free-running qemu-system-i386).
#
# Two RTL runs of the SAME image: the canonical TB (fault count 0) and the
# +VEN_SEG_ENFORCE variant (fault count 2: polarity 2's pre and post faults),
# built into a separate obj dir so obj_dir/tb_ventium stays byte-identical.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SYS="$ROOT/verif/sys"
REFS="$ROOT/ventium-refs/07-p5-emulation-harness"
QSYS="$REFS/build/qemu/build-sys/qemu-system-i386"
T="$SYS/tests/psmmmeta"
TB="$ROOT/verif/tb/obj_dir/tb_ventium"
TB_SEG="$ROOT/verif/tb/obj_dir_segmeta/tb_ventium"
OUT="$ROOT/build/sys"
mkdir -p "$OUT"

echo "== psmmmeta gate: RSM must restore the PRE-SMI hidden segment metadata =="

# --- 1. qemu-system-i386 (idempotent) + the image + both RTL testbenches ------
bash "$SYS/build-qemu-system.sh" >/dev/null
[[ -x "$QSYS" ]] || { echo "FATAL: $QSYS missing"; exit 1; }
make -C "$T" >/dev/null
make -C "$ROOT/verif/tb" rtl >/dev/null 2>&1
[[ -x "$TB" ]] || { echo "FATAL: RTL TB $TB not built"; exit 1; }
# The +VEN_SEG_ENFORCE variant: case D's expand-down D/B discrimination only
# exists when segment limits are enforced. Separate obj dir (never the
# canonical obj_dir/tb_ventium).
make -C "$ROOT/verif/tb" rtl OBJDIR=obj_dir_segmeta \
    VL_EXTRA_DEFINES='+define+VEN_SEG_ENFORCE' >/dev/null 2>&1
[[ -x "$TB_SEG" ]] || { echo "FATAL: VEN_SEG_ENFORCE TB $TB_SEG not built"; exit 1; }

# --- 2. the image runs to the isa-debug-exit under free-running qemu ----------
set +e
timeout 20 "$QSYS" -display none -machine pc -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$T/psmmmeta.bin" >/dev/null 2>&1
RC=$?
set -e
echo "  qemu free-run psmmmeta.bin: exit $RC (expected 133)"
[[ "$RC" == "133" ]] || { echo "PSMMMETA-GATE-FAIL (psmmmeta.bin did not reach the isa-debug-exit)"; exit 1; }

# --- 3. RTL runs + final-record witness grading -------------------------------
# $1 = tb, $2 = tag, $3 = expected fault count (0 canonical / 3 enforcing)
run_and_grade() {
  local tb="$1" tag="$2" want_faults="$3"
  local trace="$OUT/psmmmeta.$tag.vtrace"
  "$tb" --system --image "$T/psmmmeta.bin" --out "$trace" \
      --max-insn 60000 --quiesce 400 >/dev/null 2>&1 || true
  echo "  RTL trace ($tag): $trace ($(wc -l < "$trace") lines)"
  WANT_FAULTS="$want_faults" python3 - "$trace" <<'PYEOF'
import sys, json, os
recs = [json.loads(l) for l in open(sys.argv[1]) if l.strip() and not l.startswith('{"vtrace"')]
last = recs[-1]
H = lambda k: int(last[k], 16)
want_faults = int(os.environ["WANT_FAULTS"])
FAIL = {
  0x01: "case A: the post-RSM push differs from the pre-SMI push (ESP advance or write target changed -- leaked handler metadata)",
  0x02: "case A: an in-bounds use of the sel=0 DS was clobbered or faulted after RSM",
  0x03: "case A: an unexpected fault fired across the SMI round",
  0x11: "case B CONTROL: the pre-SMI push was not the 16-bit form (test broken, not the restore)",
  0x12: "case B: the post-RSM push is not the 16-bit form -- the handler's 32-bit ss_b LEAKED into the resumed context",
  0x21: "case C CONTROL: the pre-SMI push was not the 32-bit form (test broken, not the restore)",
  0x22: "case C: the post-RSM push is not the 32-bit form -- the handler's 16-bit ss_b LEAKED into the resumed context",
  0x30: "the handler's own stack sentinel is wrong (its mutated-width stack broke)",
  0x31: "the SMM handler never completed its protected-mode stay",
  0x32: "the handler's SMM-view sentinel is wrong",
  0x41: "case D pol1 CONTROL: the B=1 expand-down access faulted pre-SMI (test broken, not the restore)",
  0x43: "case D pol1: the post-RSM expand-down access FAULTED -- the handler's B=0 seg_b[DS] LEAKED into the resumed context",
  0x44: "case D pol2: the post-RSM expand-down access's legality differs from the pre-SMI one -- the restore changed seg_b[DS]",
  0x7D: "unexpected #GP", 0x7E: "unexpected #PF", 0x7F: "unexpected #DF",
}
edi = H("edi")
assert edi == 0x42, f"edi=0x{edi:02x} FAIL: {FAIL.get(edi, 'unknown check code')}"
assert H("esi") == 5, f"esi={last['esi']} != 5 (fewer than five SMI rounds completed)"
assert H("ebx") == 0x5AA30003, f"ebx={last['ebx']} != 0x5AA30003 (the handler's PM-stay completion sentinel)"
assert H("ebp") == 0x5AA20002, f"ebp={last['ebp']} != 0x5AA20002 (the handler's own stack broke at its mutated width)"
assert H("ecx") == want_faults, f"ecx={last['ecx']} != {want_faults} (fault count: 0 non-enforcing, 2 enforcing)"
assert H("edx") >> 16 == 0x600D, f"edx={last['edx']} != 0x600D.... (pass magic)"
assert len(recs) > 40000, f"only {len(recs)} records (anti-vacuity)"
print(f"  final record ({os.path.basename(sys.argv[1])}): edi=0x42 esi=5 ebx=0x5AA30003 ebp=0x5AA20002 ecx={want_faults} ({len(recs)} records)")
PYEOF
}

run_and_grade "$TB"     "rtl"      0
echo "  canonical:  cases A (full form discrimination) + B + C pass; case D vacuous (no enforcement)"
run_and_grade "$TB_SEG" "rtl.seg"  2
echo "  +VEN_SEG_ENFORCE: case D discriminates -- both expand-down polarities kept their pre-SMI seg_b[DS]"

echo "PSMMMETA-GATE-OK"
