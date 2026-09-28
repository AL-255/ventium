#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Short directed full-core/QEMU gate; not a gameplay or full-system acceptance.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TB_BIN:?Supply a VEN_P54_DUAL_STORE_PAIR full-core tb_ventium binary}"
TB="$(realpath "$TB_BIN")"
CONTROL="${CONTROL_TB:-}"
if [[ -n "$CONTROL" ]]; then CONTROL="$(realpath "$CONTROL")"; fi
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-dual-store.XXXXXX)}"
mkdir -p "$OUT"
ulimit -v 1048576
for spec in eligible_sat:4:0 eligible_open:4:16 alias:0:0 crossline:32:0; do
    variant="${spec%%:*}"
    fields="${spec#*:}"
    offset="${fields%%:*}"
    gap="${fields##*:}"
    as --32 --defsym "SECOND_OFFSET=$offset" --defsym "IDLE_GAP=$gap" \
        "$ROOT/verif/issue_uv/t_dual_store_pair.s" -o "$OUT/$variant.o"
    ld -m elf_i386 -Ttext 0x08048000 "$OUT/$variant.o" -o "$OUT/$variant.elf"
    nm -n "$OUT/$variant.elf" > "$OUT/$variant.sym"
    python3 "$ROOT/verif/tests/elf2flat.py" "$OUT/$variant.elf" \
        --out "$OUT/$variant.flat" --base 0x08048000
    QEMU_RESERVED_VA=256M QEMU_CPU=pentium timeout 30s \
        python3 "$ROOT/verif/qemu-trace/gen_trace.py" --qemu "$QEMU" \
        --elf "$OUT/$variant.elf" --out "$OUT/$variant.qemu.vtrace" \
        --max-insn 22000 --port "${PORT:-41491}" > "$OUT/$variant.qemu.log" 2>&1
    init_esp="$(python3 -c 'import json,sys; f=open(sys.argv[1]); next(f); print(json.loads(next(f))["esp"])' "$OUT/$variant.qemu.vtrace")"
    for mode in cycle cycle-func; do
        timeout 15s "$TB" "--$mode" --l1-axi --image "$OUT/$variant.flat" \
            --load 0x08048000 --entry 0x08048000 --init-esp "$init_esp" \
            --out "$OUT/$variant.$mode.vtrace" --max-insn 22000 \
            --max-cycles 500000 --quiesce 1000 > "$OUT/$variant.$mode.log" 2>&1
    done
    if [[ -n "$CONTROL" ]]; then
        timeout 15s "$CONTROL" --cycle --l1-axi --image "$OUT/$variant.flat" \
            --load 0x08048000 --entry 0x08048000 --init-esp "$init_esp" \
            --out "$OUT/$variant.control.vtrace" --max-insn 22000 \
            --max-cycles 500000 --quiesce 1000 > "$OUT/$variant.control.log" 2>&1
    fi
done
python3 - "$OUT" <<'PY'
import json
import os
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
keys = ('eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'esp', 'ebp',
        'eflags', 'cs', 'ss', 'ds', 'es', 'fs', 'gs')
for variant in ('eligible_sat', 'eligible_open', 'alias', 'crossline'):
    directory = out
    symbols = {p[2]: int(p[0], 16)
               for line in (directory / f'{variant}.sym').read_text().splitlines()
               if len(p := line.split()) == 3}
    def rows(mode):
        return [r for line in (directory / f'{variant}.{mode}.vtrace').read_text().splitlines()
                if 'pc' in (r := json.loads(line))]
    gold, cycle, state = [rows(mode) for mode in ('qemu', 'cycle', 'cycle-func')]
    for trace in (cycle, state):
        assert len(trace) == len(gold) + 1, (variant, len(trace), len(gold))
        assert int(trace[-1]['pc'], 0) == symbols['exit_syscall']
        trace.pop()
    assert [r['pc'] for r in gold] == [r['pc'] for r in cycle] == [r['pc'] for r in state]
    for i in range(len(gold)):
        if i + 1 < len(gold) and cycle[i]['cyc'] == cycle[i+1]['cyc']:
            continue
        for key in keys:
            assert gold[i][key] == state[i][key], (variant, i, key, gold[i], state[i])
    first = [i for i, r in enumerate(cycle) if int(r['pc'], 0) == symbols['first_store']]
    second = [i for i, r in enumerate(cycle) if int(r['pc'], 0) == symbols['second_store']]
    assert len(first) == len(second) == 1000
    pairs = sum(cycle[i]['cyc'] == cycle[j]['cyc'] for i, j in zip(first[100:], second[100:]))
    quad = os.environ.get('EXPECT_QUAD') == '1'
    if variant == 'eligible_open' or (quad and variant == 'eligible_sat'):
        assert pairs > 0, 'eligible resident stores never paired'
    else:
        assert pairs == 0, (variant, pairs)
    starts = [i for i, r in enumerate(cycle) if int(r['pc'], 0) == symbols['loop_body']]
    assert len(starts) == 1000
    clocks = cycle[starts[-1]]['cyc'] - cycle[starts[100]]['cyc']
    control_path = directory / f'{variant}.control.vtrace'
    if control_path.exists():
        control = rows('control')
        assert len(control) == len(cycle) + 1
        assert int(control[-1]['pc'], 0) == symbols['exit_syscall']
        control.pop()
        assert [r['pc'] for r in control] == [r['pc'] for r in cycle]
        control_clocks = control[starts[-1]]['cyc'] - control[starts[100]]['cyc']
        if quad and variant == 'eligible_sat':
            assert clocks < control_clocks, (variant, 'quadword buffer gave no gain', clocks, control_clocks)
        elif variant == 'eligible_open' and not quad:
            assert clocks < control_clocks, (variant, 'no pair throughput gain', clocks, control_clocks)
        else:
            assert clocks <= control_clocks, (variant, 'fallback regression', clocks, control_clocks)
        print(f'{variant}: warm paired={pairs}/900, candidate={clocks} clocks, control={control_clocks} clocks')
    else:
        print(f'{variant}: QEMU-equivalent instructions={len(gold)}, warm paired stores={pairs}/900, clocks={clocks}')
print('DUAL-STORE-CORE-GATE-OK (directed correctness and admission, not gameplay)')
PY
printf 'Artifacts: %s\n' "$OUT"
