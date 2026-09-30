#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Prebuilt, otherwise matched binaries; this script never compiles the core.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${CONTROL_TB:?Supply the raw-byte VEN_PIPE_SDECODE binary}"
: "${CANDIDATE_TB:?Supply the otherwise matched VEN_PIPE_SDISPATCH binary}"
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-pipe-sdispatch.XXXXXX)}"
mkdir -p "$OUT"
for variant in independent dependent byte_high byte_high_inc dword_to_byte byte_high_to_byte compare_consumer; do
    for profile in control candidate; do
        tb="$CONTROL_TB"
        [[ "$profile" != candidate ]] || tb="$CANDIDATE_TB"
        TB_BIN="$tb" CASE_ONLY="$variant" RAW_MEMORY=1 \
            OUTDIR="$OUT/$profile-$variant" \
            ASM_SOURCE="$ROOT/verif/issue_uv/t_pipe_sdispatch.s" \
            bash "$ROOT/verif/issue_uv/run-load-issue-ipc.sh" \
            > "$OUT/$profile-$variant.log" 2>&1
    done
done
python3 - "$OUT" <<'PY'
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
for variant in ('independent', 'dependent', 'byte_high', 'byte_high_inc',
                'dword_to_byte', 'byte_high_to_byte', 'compare_consumer'):
    measured = []
    work = []
    for profile in ('control', 'candidate'):
        directory = out / f'{profile}-{variant}'
        symbols = {p[2]: int(p[0], 16)
                   for line in (directory / f'{variant}.sym').read_text().splitlines()
                   if len(p := line.split()) == 3}
        rows = [r for line in (directory / f'{variant}.cycle.vtrace').read_text().splitlines()
                if 'pc' in (r := json.loads(line))]
        starts = [i for i, r in enumerate(rows) if int(r['pc'], 0) == symbols['loop_body']]
        assert len(starts) == 1000, (variant, profile, 'missing loop work')
        first, last = starts[100], starts[-1]
        assert last - first == 899 * 6
        measured.append(rows[last]['cyc'] - rows[first]['cyc'])
        work.append([r['pc'] for r in rows])
        if variant == 'byte_high_to_byte':
            assert symbols['loop_body'] % 32 == 31, 'missing line-straddle fixture'
    assert work[0] == work[1], (variant, 'retired instruction stream changed')
    if variant in ('dependent', 'byte_high_inc', 'compare_consumer'):
        assert measured[1] == measured[0], (variant, 'excluded shape took a shortcut', measured)
    else:
        assert measured[1] < measured[0], (variant, 'missing direct-admission saving', measured)
    print(f'{variant}: 5394 instructions control={measured[0]} '
          f'candidate={measured[1]} saved={measured[0]-measured[1]} clocks')
print('PIPE-SDISPATCH-AB-OK (architectural QEMU comparisons and admission exclusions)')
PY
printf 'Artifacts: %s\n' "$OUT"
