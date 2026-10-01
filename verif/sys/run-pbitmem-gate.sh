#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Caller-supplied frozen TB + prebuilt CASE1..8 images; never rebuilds RTL.
# OUTDIR is a fresh nonexistent absolute leaf under an existing owned parent.
set -euo pipefail
ulimit -c 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "PBITMEM-GATE-FAIL: $*" >&2; exit 1; }
: "${TB_BIN:?Provide the approved frozen tb_ventium}"
: "${OUTDIR:?Provide a fresh private absolute output directory}"
CASES="${PBITMEM_CASES:-1 2 3 4 5 6 7 8}"
[[ "$CASES" =~ ^[1-8](\ [1-8])*$ ]] || fail 'PBITMEM_CASES must contain only1..8 separated by single spaces'
declare -A selected=()
for case_id in $CASES; do
  [[ -z "${selected[$case_id]+yes}" ]] || fail "duplicate case $case_id"
  selected[$case_id]=1
done
[[ "$OUTDIR" == /* && ! -e "$OUTDIR" && ! -L "$OUTDIR" ]] || fail 'OUTDIR must be absolute, fresh and nonsymlink'
parent="$(dirname "$OUTDIR")"
[[ -d "$parent" && "$(stat -c %u "$parent")" == "$UID" && "$(realpath -m "$OUTDIR")" == "$OUTDIR" ]] || fail 'OUTDIR parent must exist, be owned, and have no symlink/dot alias'
TB="$(realpath -e "$TB_BIN")"
QSYS="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
TDIR="$ROOT/verif/sys/tests/pbitmem"
[[ -x "$TB" && -x "$QSYS" ]] || fail 'missing caller TB or private pinned QEMU (no distro fallback)'
[[ "$(sha256sum "$QSYS" | cut -d' ' -f1)" == b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd ]] || fail 'pinned QEMU binary SHA changed'
for case_id in $CASES; do
  [[ -f "$TDIR/pbitmem-c$case_id.bin" && "$(stat -c %s "$TDIR/pbitmem-c$case_id.bin")" == 65536 ]] || fail "missing/prebuilt BIOS size mismatch case $case_id"
done
if ! "$ROOT/tools/build_scope.sh" --is-active; then
  exec "$ROOT/tools/build_scope.sh" -- timeout --kill-after=5s 540s bash "$0" "$@"
fi
mkdir -m 700 "$OUTDIR"
printf 'PBITMEM artifacts: %s\n' "$OUTDIR"
sha256sum "$TB" "$QSYS" "$TDIR/pbitmem.S" "$TDIR/pbitmem.ld" "$TDIR/Makefile" \
  "$ROOT/verif/sys/run-pbitmem-gate.sh" "$ROOT/verif/qemu-trace/gen_trace.py" \
  "$ROOT/verif/diff/compare.py" "$ROOT/verif/diff/tracefmt.py" > "$OUTDIR/input.sha256"
for case_id in $CASES; do
  image="$TDIR/pbitmem-c$case_id.bin"
  out="$OUTDIR/case$case_id"
  sha256sum "$image" >> "$OUTDIR/input.sha256"
  rc=0
  timeout --kill-after=3s 20s "$QSYS" -display none -machine pc -cpu pentium -m 32 \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 -bios "$image" > "$out.free-qemu.log" 2>&1 || rc=$?
  [[ "$rc" == 133 ]] || fail "case $case_id free QEMU exit=$rc, expected133; see $out.free-qemu.log"
  timeout --kill-after=3s 90s python3 "$ROOT/verif/qemu-trace/gen_trace.py" --qemu "$QSYS" \
    --system --image "$image" --image-mode bios --cpu pentium --max-insn 14000 \
    --port "$((31300+case_id))" --out "$out.qemu.vtrace" > "$out.qemu.log" 2>&1 \
    || fail "case $case_id golden generation failed; see $out.qemu.log"
  grep -Eq '^\[gen_trace\] wrote [0-9]+ records .* \(guest exited, code=0\)$' "$out.qemu.log" \
    || fail "case $case_id golden did not reach its terminal exit"
  timeout --kill-after=3s 30s "$TB" --system --image "$image" --max-insn 14000 --quiesce 400 \
    --out "$out.rtl.vtrace" > "$out.rtl.log" 2>&1 \
    || fail "case $case_id RTL process failed; see $out.rtl.log"
  grep -Fxq 'tb: stop: quiescent for 400 clocks (core idle)' "$out.rtl.log" \
    || fail "case $case_id RTL incomplete/limit stop; see $out.rtl.log"
  PYTHONPATH="$ROOT/verif/diff" timeout --kill-after=3s 10s python3 - "$case_id" "$out.qemu.vtrace" "$out.rtl.vtrace" <<'PY'
import sys
import tracefmt as t
case = int(sys.argv[1])
pf = int(case in (3, 4, 5, 7, 8))
for path, producer in zip(sys.argv[2:], ('qemu-gdbstub', 'rtl')):
    tr = t.read_trace(path)
    assert tr.hdr.get('vtrace') == t.VERSION and tr.mode == 'func' and tr.sys, f'{path}: invalid system header'
    assert tr.hdr.get('producer') == producer, f'{path}: wrong producer'
    assert 0 < len(tr.records) < 14000, f'{path}: empty or reached instruction cap'
    keys = ['pc', 'eflags'] + t.GPR_KEYS + t.SEG_KEYS + t.SYS_CR
    for n, row in enumerate(tr.records):
        assert row.get('n') == n, f'{path}: incomplete/nonsequential n={n}'
        for key in keys:
            value = t.parse_hex(row[key])
            assert 0 <= value < (1 << t._WIDTH[key]), f'{path}: invalid {key} at{n}'
    last = tr.records[-1]
    for key, want in dict(eax=0x42, edi=0, ebx=case, ecx=pf, esi=0x600db173).items():
        assert t.parse_hex(last[key]) == want, f'{path}: terminal {key}={last[key]}, expected{want:#x}'
    print(f'PBITMEM-TERMINAL case={case} producer={producer} records={len(tr.records)} PF={pf}')
PY
  timeout --kill-after=3s 20s python3 "$ROOT/verif/diff/compare.py" --mode func --all \
    "$out.qemu.vtrace" "$out.rtl.vtrace" > "$out.diff.log" 2>&1 \
    || fail "case $case_id full architectural diff failed; see $out.diff.log"
  printf 'PBITMEM-PASS case=%s\n' "$case_id"
done
sha256sum -c "$OUTDIR/input.sha256" > "$OUTDIR/input-stability.log" \
  || fail "input changed during gate; see $OUTDIR/input-stability.log"
echo "PBITMEM-GATE-OK: all selected cases [$CASES] completed and matched; not standard-suite acceptance"
