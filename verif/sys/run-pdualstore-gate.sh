#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Protected/paged full-core U/V store-pair microbenchmark. No full verification.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TB_BIN:?Supply a VEN_P54_DUAL_STORE_PAIR system tb_ventium binary}"
TB="$(realpath "$TB_BIN")"
[[ -x "$TB" ]] || { echo "Not executable: $TB" >&2; exit 2; }
CONTROL="${CONTROL_TB:-}"
if [[ -n "$CONTROL" ]]; then
  CONTROL="$(realpath "$CONTROL")"
  [[ -x "$CONTROL" ]] || { echo "Not executable: $CONTROL" >&2; exit 2; }
fi
OUTDIR="${OUTDIR:-$(mktemp -d /tmp/ventium-pdualstore.XXXXXX)}"
export OUTDIR
mkdir -p "$OUTDIR"
TDIR="$ROOT/verif/sys/tests/pdualstore"
GOLD="$OUTDIR/pdualstore.sys.vtrace"

timeout 180s bash "$ROOT/verif/sys/run-sys-golden.sh" pdualstore \
  >"$OUTDIR/golden.log" 2>&1 || {
    tail -n 80 "$OUTDIR/golden.log"; exit 1;
  }
nm -n "$TDIR/pdualstore.elf" >"$OUTDIR/pdualstore.sym"
for mode in cycle cycle-func; do
  timeout 45s "$TB" "--$mode" --system --l1-axi \
    --image "$TDIR/pdualstore.bin" \
    --out "$OUTDIR/pdualstore.$mode.vtrace" --max-insn 5000 --quiesce 8000 \
    >"$OUTDIR/pdualstore.$mode.log" 2>&1 || {
      tail -n 80 "$OUTDIR/pdualstore.$mode.log"; exit 1;
    }
done
if [[ -n "$CONTROL" ]]; then
  timeout 45s "$CONTROL" --cycle --system --l1-axi \
    --image "$TDIR/pdualstore.bin" \
    --out "$OUTDIR/pdualstore.control.vtrace" --max-insn 5000 --quiesce 8000 \
    >"$OUTDIR/pdualstore.control.log" 2>&1 || {
      tail -n 80 "$OUTDIR/pdualstore.control.log"; exit 1;
    }
fi

python3 - "$OUTDIR" <<'PY'
import json
from pathlib import Path
import sys

out = Path(sys.argv[1])
def rows(name):
    return [r for line in (out / f'pdualstore.{name}.vtrace').read_text().splitlines()
            if 'pc' in (r := json.loads(line))]

symbols = {p[2]: int(p[0], 16)
           for line in (out / 'pdualstore.sym').read_text().splitlines()
           if len(p := line.split()) == 3}
gold, cycle, state = (rows(name) for name in ('sys', 'cycle', 'cycle-func'))
assert len(gold) == len(cycle) == len(state), \
    ('trace lengths', len(gold), len(cycle), len(state))
assert [r['pc'] for r in gold] == [r['pc'] for r in cycle] == [r['pc'] for r in state], \
    'PC stream differs from QEMU'
keys = ('eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'esp', 'ebp',
        'cs', 'ss', 'ds', 'es', 'fs', 'gs', 'cr0', 'cr2', 'cr3', 'cr4')
compared = 0
for i, (expected, observed) in enumerate(zip(gold, state)):
    if i + 1 < len(cycle) and cycle[i]['cyc'] == cycle[i+1]['cyc']:
        continue  # U's mid-pair snapshot is not a separate post-commit state.
    for key in keys:
        assert expected[key] == observed[key], (i, key, expected[key], observed[key])
    assert (int(expected['eflags'], 0) & 0x003f7fd5) == \
           (int(observed['eflags'], 0) & 0x003f7fd5), (i, 'eflags')
    compared += 1
assert compared > 0
last = state[-1]
for key, want in (('ebp', 0x13579bdf), ('esi', 0xcafebabe),
                  ('ecx', 3), ('edx', 0x4000f4), ('edi', 3)):
    assert int(last[key], 0) == want, (key, last[key], want)

u = [i for i, r in enumerate(cycle)
     if int(r['pc'], 0) == symbols['pdualstore_loop_u']]
v = [i for i, r in enumerate(cycle)
     if int(r['pc'], 0) == symbols['pdualstore_loop_v']]
assert len(u) == len(v) == 128, ('loop visits', len(u), len(v))
pairs = sum(cycle[i]['cyc'] == cycle[j]['cyc'] for i, j in zip(u, v))
assert pairs > 0, 'no protected/paged resident store pairs retired'
clocks = cycle[u[-1]]['cyc'] - cycle[u[8]]['cyc']
if (out / 'pdualstore.control.vtrace').exists():
    control = rows('control')
    assert len(control) == len(cycle), ('control length', len(control), len(cycle))
    assert [r['pc'] for r in control] == [r['pc'] for r in cycle], \
        'control PC stream differs'
    control_clocks = control[u[-1]]['cyc'] - control[u[8]]['cyc']
    # The idle NOP window intentionally drains both write slots. Its fixed
    # frontend/branch cadence can hide the one-cycle pair retirement saving,
    # so this test grades protected-mode admission + no throughput regression;
    # the saturated/open user-mode gate grades actual throughput gain.
    assert clocks <= control_clocks, ('throughput regression', clocks, control_clocks)
    print(f'pdualstore: groups={compared}, paired={pairs}/128, '
          f'candidate={clocks} clocks, control={control_clocks} clocks, '
          f'end-to-end={cycle[-1]["cyc"]}/{control[-1]["cyc"]} clocks')
else:
    print(f'pdualstore: groups={compared}, paired={pairs}/128, clocks={clocks}')
print('PDUALSTORE-GATE-OK (QEMU-equivalent paging, fault/restart and store data)')
PY
printf 'Artifacts: %s\n' "$OUTDIR"
