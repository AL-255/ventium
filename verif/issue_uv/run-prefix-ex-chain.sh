#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# PREPARED, NOT RUN: non-CoreMark verification deferred until >2.0 CM/MHz.
# Uses prebuilt binaries only; never starts Verilator or updates goldens.
set -euo pipefail
if [[ "${VENTIUM_PREFIX_CHAIN_DEADLINE:-0}" != 1 ]]; then
  exec env VENTIUM_PREFIX_CHAIN_DEADLINE=1 timeout 540s bash "$0" "$@"
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TB_BIN:?Supply the experimental chain candidate binary}"
TB="$(realpath "$TB_BIN")"
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-prefix-ex-chain.XXXXXX)}"
mkdir -p "$OUT"
expect_chain="${EXPECT_CHAIN:-1}"
[[ "$expect_chain" == 0 || "$expect_chain" == 1 ]] || { echo 'Invalid EXPECT_CHAIN'; exit 2; }
memory_args=()
[[ "${RAW_MEMORY:-1}" == 1 ]] || memory_args=(--l1-axi)
ulimit -v 1048576
cases=()
for old in 0 1; do
  for next in 0 1 2 3 4; do
    for mem in 0 1; do cases+=("${old}_${next}_${mem}_0"); done
  done
done
for next in 0 1 2 3 4; do cases+=("1_${next}_1_1"); done
[[ -z "${CASE_ONLY:-}" ]] || cases=("$CASE_ONLY")
for case_id in "${cases[@]}"; do
  [[ "$case_id" =~ ^[01]_[0-4]_[01]_[01]$ ]] || { echo 'Invalid CASE_ONLY'; exit 2; }
  IFS=_ read -r old next mem hazard <<< "$case_id"
  [[ "$hazard" == 0 || ( "$old" == 1 && "$mem" == 1 ) ]] || {
    echo 'EA hazard requires older IMUL and next memory'; exit 2;
  }
  as --32 --defsym OLD="$old" --defsym NEXT="$next" --defsym MEM="$mem" \
    --defsym HAZARD="$hazard" "$ROOT/verif/issue_uv/t_prefix_ex_chain.s" -o "$OUT/$case_id.o"
  ld -m elf_i386 -Ttext 0x08048000 "$OUT/$case_id.o" -o "$OUT/$case_id.elf"
  nm -n "$OUT/$case_id.elf" > "$OUT/$case_id.sym"
  python3 "$ROOT/verif/tests/elf2flat.py" "$OUT/$case_id.elf" \
    --out "$OUT/$case_id.flat" --base 0x08048000 > "$OUT/$case_id.flat.log"
  QEMU_RESERVED_VA=256M QEMU_CPU=pentium timeout 45s \
    python3 "$ROOT/verif/qemu-trace/gen_trace.py" --qemu "$QEMU" \
    --elf "$OUT/$case_id.elf" --out "$OUT/$case_id.qemu.vtrace" \
    --max-insn 1024 --port "${PORT:-41435}" > "$OUT/$case_id.qemu.log" 2>&1
  init_esp="$(python3 -c 'import json,sys; f=open(sys.argv[1]); next(f); print(json.loads(next(f))["esp"])' "$OUT/$case_id.qemu.vtrace")"
  for mode in cycle cycle-func; do
    timeout 15s "$TB" "--$mode" "${memory_args[@]}" +ven_prefix_chainlog \
      --image "$OUT/$case_id.flat" --load 0x08048000 --entry 0x08048000 \
      --init-esp "$init_esp" --out "$OUT/$case_id.$mode.vtrace" \
      --max-insn 1024 --max-cycles 200000 --quiesce 1000 > "$OUT/$case_id.$mode.log" 2>&1
  done
done
python3 - "$OUT" "$expect_chain" "${cases[@]}" <<'PY'
import json
import pathlib
import re
import sys

out = pathlib.Path(sys.argv[1])
expect_chain = int(sys.argv[2])
keys = ('eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'esp', 'ebp',
        'eflags', 'cs', 'ss', 'ds', 'es', 'fs', 'gs')
for case in sys.argv[3:]:
    old, next_op, memory, hazard = map(int, case.split('_'))
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
    indices = [i for i, r in enumerate(cycle) if int(r['pc'], 0) == symbols['tested_next']]
    assert len(indices) == 64
    assert all(int(cycle[i - 1]['pc'], 0) == symbols['tested_old'] for i in indices)
    clocks = [cycle[i]['cyc'] - cycle[i - 1]['cyc'] for i in indices[16:]]
    occupancy = 3 if next_op == 0 else 10
    # Do not invent a universal additive prefix floor: some can legally
    # overlap an older instruction/AGI. Consecutive EXT is separately pinned
    # to Intel's explicit four-clock example, not an inferred three.
    floor = 4 if old == 0 and next_op == 0 else occupancy
    assert min(clocks) >= floor, (case, 'execution floor undercharged', min(clocks), floor)
    eligible = expect_chain and not hazard and next_op != 4 and not (old == 0 and next_op == 0)
    for mode in ('cycle', 'cycle-func'):
        hits = re.findall(r'\[P54PREFIXCHAIN\] old_pc=([0-9a-f]+) next_pc=([0-9a-f]+)',
                          (out / f'{case}.{mode}.log').read_text())
        hits = [(int(a, 16), int(b, 16)) for a, b in hits]
        assert len(hits) == (64 if eligible else 0), (case, mode, 'admission/veto', len(hits))
        assert all(a == symbols['tested_old'] and b == symbols['tested_next'] for a, b in hits)
    if eligible:
        assert min(clocks) == max(clocks) == occupancy, (case, 'overlap missing', clocks)
    print(f'{case}: full QEMU state/PC; chain={bool(eligible)}; 48 warm gaps={min(clocks)}..{max(clocks)}')
print('PREFIX-EX-CHAIN-OK (architectural/physical hold only; P54 microcode qualification remains open)')
PY
printf 'Artifacts: %s\n' "$OUT"
