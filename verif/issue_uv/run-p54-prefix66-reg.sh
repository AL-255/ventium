#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# One focused case using a prebuilt combined candidate; no compile/saved state.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TB_BIN:?Supply the full-core PREFIX66 candidate binary}"
TB="$(realpath "$TB_BIN")"
case_id="${CASE_ONLY:-0}"
[[ "$case_id" =~ ^([0-9]|1[01])$ ]] || { echo 'CASE_ONLY must be 0..11'; exit 2; }
pad="${LOOP_PAD:-0}"
[[ "$pad" =~ ^[0-9]{1,2}$ ]] && (( 10#$pad<=31 )) || {
  echo 'LOOP_PAD must be0..31'; exit 2;
}
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-prefix66-reg.XXXXXX)}"
mkdir -p "$OUT"
ulimit -v 1048576
memory_args=()
case "${RAW_MEMORY:-1}" in
  1) ;;
  0) memory_args=(--l1-axi) ;;
  *) echo 'RAW_MEMORY must be0 or1'; exit 2 ;;
esac
as --32 --defsym CASE="$case_id" --defsym LOOP_PAD="$pad" \
  "$ROOT/verif/issue_uv/t_prefix66_reg.s" -o "$OUT/test.o"
link_args=()
# Only the actual self-modifying-code witness needs writable executable text.
# QEMU must observe the real store, not a fault caused by ELF page permissions.
[[ "$case_id" == 10 ]] && link_args=(-T "$ROOT/verif/issue_uv/prefix66_rwx.ld")
ld -m elf_i386 "${link_args[@]}" -Ttext 0x08048000 "$OUT/test.o" -o "$OUT/test.elf"
nm -n "$OUT/test.elf" > "$OUT/test.sym"
python3 "$ROOT/verif/tests/elf2flat.py" "$OUT/test.elf" \
  --out "$OUT/test.flat" --base 0x08048000 > "$OUT/flat.log"
QEMU_RESERVED_VA=256M QEMU_CPU=pentium timeout 90s \
  python3 "$ROOT/verif/qemu-trace/gen_trace.py" --qemu "$QEMU" \
  --elf "$OUT/test.elf" --out "$OUT/test.qemu.vtrace" \
  --max-insn 12000 --port "${PORT:-41425}" > "$OUT/qemu.log" 2>&1
init_esp="$(python3 -c 'import json,sys; f=open(sys.argv[1]); next(f); print(json.loads(next(f))["esp"])' "$OUT/test.qemu.vtrace")"
for mode in cycle cycle-func; do
  timeout 30s "$TB" "--$mode" "${memory_args[@]}" --image "$OUT/test.flat" \
    --load 0x08048000 --entry 0x08048000 --init-esp "$init_esp" \
    --out "$OUT/test.$mode.vtrace" --max-insn 12000 \
    --max-cycles 200000 --quiesce 1000 > "$OUT/$mode.log" 2>&1
done
python3 "$ROOT/verif/issue_uv/check-p54-prefix66-reg.py" "$OUT" "$case_id"
printf 'Artifacts: %s\n' "$OUT"
