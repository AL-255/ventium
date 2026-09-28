#!/usr/bin/env bash
# Protected/paged U-load + V ALU-memory pairing and V-fault fallback.
# Short directed QEMU differential, not a full verification run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TB_BIN:?Supply a VEN_P54_DUAL_READ_ALU_PAIR system tb_ventium binary}"
: "${CONTROL_TB:?Supply the matched no-DUAL_READ_ALU control binary}"
TB="$(realpath "$TB_BIN")"
CONTROL="$(realpath "$CONTROL_TB")"
OUTDIR="${OUTDIR:-$(mktemp -d /tmp/ventium-pdualreadalu.XXXXXX)}"
mkdir -p "$OUTDIR"
TDIR="$ROOT/verif/sys/tests/pdualreadalu"
timeout 180s bash "$ROOT/verif/sys/run-sys-golden.sh" pdualreadalu \
    >"$OUTDIR/golden.log" 2>&1 || { tail -60 "$OUTDIR/golden.log"; exit 1; }
nm -n "$TDIR/pdualreadalu.elf" > "$OUTDIR/pdualreadalu.sym"
for mode in cycle cycle-func; do
    timeout 45s "$TB" "--$mode" --system --l1-axi \
        --image "$TDIR/pdualreadalu.bin" \
        --out "$OUTDIR/pdualreadalu.$mode.vtrace" --max-insn 5000 --quiesce 8000 \
        >"$OUTDIR/pdualreadalu.$mode.log" 2>&1 || {
            tail -60 "$OUTDIR/pdualreadalu.$mode.log"; exit 1;
        }
done
timeout 45s "$CONTROL" --cycle --system --l1-axi \
    --image "$TDIR/pdualreadalu.bin" \
    --out "$OUTDIR/pdualreadalu.control.vtrace" --max-insn 5000 --quiesce 8000 \
    >"$OUTDIR/pdualreadalu.control.log" 2>&1 || {
        tail -60 "$OUTDIR/pdualreadalu.control.log"; exit 1;
    }
python3 - "$OUTDIR" <<'PY'
import json
from pathlib import Path
import sys

out = Path(sys.argv[1])
def rows(mode):
    return [r for line in (out / f'pdualreadalu.{mode}.vtrace').read_text().splitlines()
            if 'pc' in (r := json.loads(line))]
symbols = {parts[2]: int(parts[0], 16)
           for line in (out / 'pdualreadalu.sym').read_text().splitlines()
           if len(parts := line.split()) == 3}
gold, cycle, state, control = (rows(m) for m in ('sys', 'cycle', 'cycle-func', 'control'))
assert len(gold) == len(cycle) == len(state) == len(control), \
    ('trace lengths', len(gold), len(cycle), len(state), len(control))
assert [r['pc'] for r in gold] == [r['pc'] for r in cycle] == \
       [r['pc'] for r in state] == [r['pc'] for r in control], 'PC stream differs from QEMU'
keys = ('eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'esp', 'ebp',
        'cs', 'ss', 'ds', 'es', 'fs', 'gs', 'cr0', 'cr2', 'cr3', 'cr4')
compared = 0
for i, (expected, observed) in enumerate(zip(gold, state)):
    if i + 1 < len(cycle) and cycle[i]['cyc'] == cycle[i+1]['cyc']:
        continue
    for key in keys:
        assert expected[key] == observed[key], (i, key, expected[key], observed[key])
    assert (int(expected['eflags'], 0) & 0x003f7fd5) == \
           (int(observed['eflags'], 0) & 0x003f7fd5), (i, 'eflags')
    compared += 1
assert compared > 0
last = state[-1]
for key, want in (('ebp', 896), ('esi', 0x1244), ('ecx', 3),
                  ('edx', 0x4000f4), ('edi', 0), ('cr2', 0x401000)):
    assert int(last[key], 0) == want, (key, last[key], want)
fault_u = [i for i, r in enumerate(cycle)
           if int(r['pc'], 0) == symbols['pdualreadalu_fault_u']]
fault_v = [i for i, r in enumerate(cycle)
           if int(r['pc'], 0) == symbols['pdualreadalu_fault_v']]
assert len(fault_u) == 1 and len(fault_v) == 2
assert cycle[fault_u[0]]['cyc'] != cycle[fault_v[0]]['cyc'], 'faulting V paired with U'
assert int(state[fault_v[0]]['ebx'], 0) == 0x10, 'faulting V changed destination'
assert int(state[fault_v[0]]['cr2'], 0) == 0x401000, 'wrong faulting address'
assert int(state[fault_v[1]]['ebx'], 0) == 0x1244, 'V restart lost the ALU result'
u = [i for i, r in enumerate(cycle)
     if int(r['pc'], 0) == symbols['pdualreadalu_loop_u']]
v = [i for i, r in enumerate(cycle)
     if int(r['pc'], 0) == symbols['pdualreadalu_loop_v']]
assert len(u) == len(v) == 128
pairs = sum(cycle[i]['cyc'] == cycle[j]['cyc'] for i, j in zip(u, v))
assert pairs >= 100, ('too few protected/paged V ALU pairs', pairs)
clocks = cycle[u[-1]]['cyc'] - cycle[u[8]]['cyc']
baseline = control[u[-1]]['cyc'] - control[u[8]]['cyc']
assert clocks <= baseline, ('throughput regression', clocks, baseline)
print(f'pdualreadalu: QEMU-equivalent groups={compared}, paired={pairs}/128, '
      f'candidate={clocks}, control={baseline} clocks')
print('PDUALREADALU-GATE-OK (paging, fault/restart, V flags/data; not gameplay)')
PY
printf 'Artifacts: %s\n' "$OUTDIR"
