#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# One prepared full-core case per invocation, using a prebuilt binary. No build,
# no snapshots, no score claim. Parent may fan out distinct CASE_ONLY/PORT jobs
# after the parent authorizes bounded directed qualification. No full-system
# run or score claim is performed by this script.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TB_BIN:?Supply the full-core COMMON candidate binary}"
TB="$(realpath "$TB_BIN")"
case_id="${CASE_ONLY:-0}"
[[ "$case_id" =~ ^([0-9]|1[0-3])$ ]] || {
  echo 'CASE_ONLY must be between 0 and 13'; exit 2;
}
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-agi-write-mask.XXXXXX)}"
mkdir -p "$OUT"
ulimit -v 1048576
memory_args=()
case "${RAW_MEMORY:-1}" in
  1) ;;
  0) memory_args=(--l1-axi) ;;
  *) echo 'RAW_MEMORY must be 0 or 1'; exit 2 ;;
esac
as --32 --defsym CASE="$case_id" "$ROOT/verif/issue_uv/t_agi_write_mask.s" \
  -o "$OUT/test.o"
ld -m elf_i386 -Ttext 0x08048000 "$OUT/test.o" -o "$OUT/test.elf"
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
python3 - "$OUT" "$case_id" <<'PY'
import json
import pathlib
import sys

out, case = pathlib.Path(sys.argv[1]), int(sys.argv[2])
symbols = {p[2]: int(p[0], 16) for line in (out / 'test.sym').read_text().splitlines()
           if len(p := line.split()) == 3}
keys = ('eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'esp', 'ebp',
        'eflags', 'cs', 'ss', 'ds', 'es', 'fs', 'gs')
def rows(mode):
    return [r for line in (out / f'test.{mode}.vtrace').read_text().splitlines()
            if 'pc' in (r := json.loads(line))]
gold, cycle, state = [rows(mode) for mode in ('qemu', 'cycle', 'cycle-func')]
for trace in (cycle, state):
    assert len(trace) == len(gold) + 1, ('incomplete program', len(trace), len(gold))
    assert int(trace[-1]['pc'], 0) == symbols['exit_syscall']
    trace.pop()  # QEMU has no architectural packet for the exit syscall.
assert [r['pc'] for r in gold] == [r['pc'] for r in cycle] == [r['pc'] for r in state]
for i in range(len(gold)):
    if i + 1 < len(gold) and cycle[i]['cyc'] == cycle[i+1]['cyc']:
        continue  # Paired post-state belongs to the end of the retirement group.
    for key in keys:
        assert gold[i][key] == state[i][key], (case, i, key, gold[i], state[i])
indices = [i for i, r in enumerate(cycle) if int(r['pc'], 0) == symbols['tested_op']]
assert len(indices) == 1000
gaps = [cycle[i]['cyc'] - cycle[i-1]['cyc'] for i in indices[100:]]
# The register producer's write edge followed by an unprefixed dependent
# address must include AGI plus the following consumer's own clock. The other
# cases only report actual spacing: valid V-memory pairing can make it zero.
if case in range(2, 11):
    assert min(gaps) >= 2, ('true prior-clock dependency undercharged', case, min(gaps))
print(f'P54-AGI-WRITE-MASK-CASE-OK case={case} QEMU-state=PASS '
      f'warm_consumer_gaps={min(gaps)}..{max(gaps)} clocks')
PY
printf 'Artifacts: %s\n' "$OUT"
