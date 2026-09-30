#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Prebuilt-binary, one-case gate. Fan out only with distinct PORT/OUTDIR.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TB_BIN:?Supply a full-core candidate binary}"
TB="$(realpath "$TB_BIN")"
case_id="${CASE_ONLY:-0}"
[[ "$case_id" =~ ^([0-9]|10)$ ]] || { echo 'CASE_ONLY must be 0..10'; exit 2; }
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-ctrl-target-read.XXXXXX)}"
mkdir -p "$OUT"
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
ulimit -v 1048576
as --32 --defsym CASE="$case_id" "$ROOT/verif/issue_uv/t_ctrl_target_read.s" -o "$OUT/test.o"
link_args=()
# Own-store coherence needs an actually writable executable segment in the
# QEMU golden too; do not mistake a host ELF protection fault for stale RTL.
[[ "$case_id" != 8 ]] || link_args=(-N)
ld -m elf_i386 "${link_args[@]}" -Ttext 0x00008000 "$OUT/test.o" -o "$OUT/test.elf"
nm -n "$OUT/test.elf" > "$OUT/test.sym"
python3 "$ROOT/verif/tests/elf2flat.py" "$OUT/test.elf" \
  --out "$OUT/test.flat" --base 0x00008000 > "$OUT/flat.log"
QEMU_RESERVED_VA=256M QEMU_CPU=pentium timeout 90s \
  python3 "$ROOT/verif/qemu-trace/gen_trace.py" --qemu "$QEMU" \
  --elf "$OUT/test.elf" --out "$OUT/test.qemu.vtrace" \
  --max-insn 18000 --port "${PORT:-41500}" > "$OUT/qemu.log" 2>&1
init_esp="$(python3 -c 'import json,sys; f=open(sys.argv[1]); next(f); print(json.loads(next(f))["esp"])' "$OUT/test.qemu.vtrace")"
for mode in cycle cycle-func; do
  timeout 30s "$TB" "--$mode" --image "$OUT/test.flat" \
    --load 0x00008000 --entry 0x00008000 --init-esp "$init_esp" \
    --out "$OUT/test.$mode.vtrace" --max-insn 18000 \
    --max-cycles 300000 --quiesce 1000 > "$OUT/$mode.log" 2>&1
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
    trace.pop()
assert int(state[-1]['ebx'], 0) == 0, ('guest failed', case)
assert [r['pc'] for r in gold] == [r['pc'] for r in cycle] == [r['pc'] for r in state]
for i in range(len(gold)):
    if i + 1 < len(gold) and cycle[i]['cyc'] == cycle[i+1]['cyc']:
        continue
    for key in keys:
        assert gold[i][key] == state[i][key], (case, i, key, gold[i], state[i])
starts = [r['cyc'] for r in cycle if int(r['pc'], 0) == symbols['loop_body']]
assert len(starts) == 1000
gaps = [b-a for a,b in zip(starts[100:], starts[101:])]
print(f'P54-CTRL-TARGET-READ-CASE-OK case={case} QEMU-state=PASS '
      f'warm_iteration_gaps={min(gaps)}..{max(gaps)} clocks '
      f'warm_clocks={starts[-1]-starts[100]}')
PY
printf 'Artifacts: %s\n' "$OUT"
