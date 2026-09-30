#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Prebuilt binary only. Checks actual result-retire latency, not a penalty
# inserted after the result has already become architectural.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TB_BIN:?Supply the period-correct timing candidate binary}"
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-ext-execution.XXXXXX)}"
mkdir -p "$OUT"
for variant in independent dependent byte_high byte_high_inc; do
    CASE_ONLY="$variant" RAW_MEMORY="${RAW_MEMORY:-1}" \
        OUTDIR="$OUT/$variant" \
        ASM_SOURCE="$ROOT/verif/issue_uv/t_ext_execution_latency.s" \
        bash "$ROOT/verif/issue_uv/run-load-issue-ipc.sh" \
        > "$OUT/$variant.log" 2>&1
done
python3 - "$OUT" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
for variant in ('independent', 'dependent', 'byte_high', 'byte_high_inc'):
    directory = out / variant
    symbols = {p[2]: int(p[0], 16)
               for line in (directory / f'{variant}.sym').read_text().splitlines()
               if len(p := line.split()) == 3}
    rows = [r for line in (directory / f'{variant}.cycle.vtrace').read_text().splitlines()
            if 'pc' in (r := json.loads(line))]
    starts = [i for i, r in enumerate(rows) if int(r['pc'], 0) == symbols['loop_body']]
    assert len(starts) == 1000
    delays = [rows[i]['cyc'] - rows[i - 1]['cyc'] for i in starts[100:]]
    assert min(delays) >= 4, (variant, 'EXT architectural result committed too early', min(delays))
    assert all(int(rows[i + 1]['pc'], 0) == symbols['loop_body'] + 3 for i in starts)
    print(f'{variant}: 900 warm result-retire delays, minimum={min(delays)} clocks')
print('EXT-EXECUTION-LATENCY-OK (all states QEMU-checked; period minimum is conservative)')
PY
printf 'Artifacts: %s\n' "$OUT"
