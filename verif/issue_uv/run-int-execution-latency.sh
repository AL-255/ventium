#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Uses a prebuilt full-core candidate; never starts Verilator or alters goldens.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TB_BIN:?Supply the period-correct full-core candidate binary}"
TB="$(realpath "$TB_BIN")"
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-int-execution.XXXXXX)}"
mkdir -p "$OUT"
cl_count="${CL_COUNT:-1}"
loop_pad="${LOOP_PAD:-0}"
high8="${HIGH8:-0}"
[[ "$cl_count" =~ ^[0-9]{1,3}$ ]] && (( 10#$cl_count <= 255 )) || {
  echo 'CL_COUNT must be a byte value'; exit 2;
}
[[ "$loop_pad" =~ ^[0-9]{1,2}$ ]] && (( 10#$loop_pad <= 31 )) || {
  echo 'LOOP_PAD must be between 0 and 31'; exit 2;
}
[[ "$high8" == 0 || "$high8" == 1 ]] || { echo 'HIGH8 must be 0 or 1'; exit 2; }
memory_args=()
[[ "${RAW_MEMORY:-1}" == 1 ]] || memory_args=(--l1-axi)
ulimit -v 1048576
cases=()
for op in 0 1 2 3 4 5; do
  for width in 8 16 32; do
    [[ "$width" != 8 || ( "$op" != 2 && "$op" != 3 ) ]] || continue
    for memory in 0 1; do cases+=("${op}_${width}_${memory}"); done
  done
done
[[ -z "${CASE_ONLY:-}" ]] || cases=("$CASE_ONLY")
for case_id in "${cases[@]}"; do
  [[ "$case_id" =~ ^([0-9]|1[01])_(8|16|32)_[01]$ ]] || { echo 'Invalid CASE_ONLY'; exit 2; }
  IFS=_ read -r op width memory <<< "$case_id"
  [[ "$width" != 8 || ( "$op" != 2 && "$op" != 3 && "$op" != 6 ) ]] || {
    echo 'Two/three-operand IMUL has no byte encoding'; exit 2;
  }
  as --32 --defsym OP="$op" --defsym WIDTH="$width" --defsym MEM="$memory" \
    --defsym COUNT="$cl_count" --defsym HIGH8="$high8" --defsym LOOP_PAD="$loop_pad" \
    "$ROOT/verif/issue_uv/t_int_execution_latency.s" -o "$OUT/$case_id.o"
  ld -m elf_i386 -Ttext 0x08048000 "$OUT/$case_id.o" -o "$OUT/$case_id.elf"
  nm -n "$OUT/$case_id.elf" > "$OUT/$case_id.sym"
  python3 "$ROOT/verif/tests/elf2flat.py" "$OUT/$case_id.elf" \
    --out "$OUT/$case_id.flat" --base 0x08048000 > "$OUT/$case_id.flat.log"
  QEMU_RESERVED_VA=256M QEMU_CPU=pentium timeout 45s \
    python3 "$ROOT/verif/qemu-trace/gen_trace.py" --qemu "$QEMU" \
    --elf "$OUT/$case_id.elf" --out "$OUT/$case_id.qemu.vtrace" \
    --max-insn 410 --port "${PORT:-41431}" > "$OUT/$case_id.qemu.log" 2>&1
  init_esp="$(python3 -c 'import json,sys; f=open(sys.argv[1]); next(f); print(json.loads(next(f))["esp"])' "$OUT/$case_id.qemu.vtrace")"
  for mode in cycle cycle-func; do
    timeout 15s "$TB" "--$mode" "${memory_args[@]}" --image "$OUT/$case_id.flat" \
      --load 0x08048000 --entry 0x08048000 --init-esp "$init_esp" \
      --out "$OUT/$case_id.$mode.vtrace" --max-insn 410 \
      --max-cycles 200000 --quiesce 1000 > "$OUT/$case_id.$mode.log" 2>&1
  done
done
python3 - "$OUT" "${cases[@]}" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
keys = ('eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'esp', 'ebp',
        'eflags', 'cs', 'ss', 'ds', 'es', 'fs', 'gs')
for case in sys.argv[2:]:
    op, width, memory = map(int, case.split('_'))
    symbols = {p[2]: int(p[0], 16) for line in (out / f'{case}.sym').read_text().splitlines()
               if len(p := line.split()) == 3}
    def rows(mode):
        return [r for line in (out / f'{case}.{mode}.vtrace').read_text().splitlines()
                if 'pc' in (r := json.loads(line))]
    gold, cycle, state = [rows(mode) for mode in ('qemu', 'cycle', 'cycle-func')]
    for trace in (cycle, state):
        assert len(trace) == len(gold) + 1, (case, 'incomplete program', len(trace), len(gold))
        assert int(trace[-1]['pc'], 0) == symbols['exit_syscall']
        trace.pop()
    assert [r['pc'] for r in gold] == [r['pc'] for r in cycle] == [r['pc'] for r in state]
    for i in range(len(gold)):
        if i + 1 < len(gold) and cycle[i]['cyc'] == cycle[i + 1]['cyc']:
            continue
        for key in keys:
            assert gold[i][key] == state[i][key], (case, i, key, gold[i], state[i])
    indices = [i for i, r in enumerate(cycle) if int(r['pc'], 0) == symbols['tested_op']]
    assert len(indices) == 64
    occupancy = (11 if width < 32 else 10) if op < 2 else 10 if op in (2, 3, 6) else (
        {8: 17, 16: 25, 32: 41} if op == 4 else {8: 22, 16: 30, 32: 46})[width] if op < 7 else 4
    # Ordinary 66 and non-Jcc 0F are D1 work, never credits against EX occupancy.
    minimum = occupancy + int(width == 16) + int(op == 2)
    delays = [cycle[i]['cyc'] - cycle[i-1]['cyc'] for i in indices[16:]]
    assert min(delays) >= minimum, (case, 'result committed before EX+prefix floor', min(delays), minimum)
    print(f'{case}: QEMU state checked; 48 warm result-retire intervals, '
          f'clocks={min(delays)}..{max(delays)}, period floor={minimum}')
print('INT-EXECUTION-LATENCY-OK')
PY
printf 'Artifacts: %s\n' "$OUT"
