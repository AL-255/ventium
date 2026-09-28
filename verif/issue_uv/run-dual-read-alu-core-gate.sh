#!/usr/bin/env bash
# Directed full-core/QEMU U-load + V read-only ALU pairing; never full verify.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${TB_BIN:?Supply a VEN_P54_DUAL_READ_ALU_PAIR tb_ventium binary}"
: "${CONTROL_TB:?Supply the matched no-DUAL_READ_ALU control binary}"
TB="$(realpath "$TB_BIN")"
CONTROL="$(realpath "$CONTROL_TB")"
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-dual-read-alu.XXXXXX)}"
mkdir -p "$OUT"
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
for spec in add_bank:0:0:4 add_alias:0:0:0 add_crossline:0:0:32 \
            cmp_bank:0:1:4 cmp_alias:0:1:0 cmp_crossline:0:1:32 \
            uadd_bank:1:0:4 uadd_alias:1:0:0 uadd_crossline:1:0:32 \
            ucmp_bank:2:0:4 back2back:0:0:4 alu_back2back:1:0:4; do
    IFS=: read -r variant umode mode offset <<< "$spec"
    source="$ROOT/verif/issue_uv/t_dual_read_alu_pair.s"
    if [[ "$variant" == *back2back ]]; then
        source="$ROOT/verif/issue_uv/t_dual_read_alu_back2back.s"
    fi
    as --32 --defsym "UMODE=$umode" --defsym "MODE=$mode" --defsym "SECOND_OFFSET=$offset" \
        "$source" -o "$OUT/$variant.o"
    ld -m elf_i386 -Ttext 0x08048000 "$OUT/$variant.o" -o "$OUT/$variant.elf"
    nm -n "$OUT/$variant.elf" > "$OUT/$variant.sym"
    python3 "$ROOT/verif/tests/elf2flat.py" "$OUT/$variant.elf" \
        --out "$OUT/$variant.flat" --base 0x08048000 >/dev/null
    QEMU_RESERVED_VA=256M QEMU_CPU=pentium timeout 30s \
        python3 "$ROOT/verif/qemu-trace/gen_trace.py" --qemu "$QEMU" \
        --elf "$OUT/$variant.elf" --out "$OUT/$variant.qemu.vtrace" \
        --max-insn 9000 --port "${PORT:-41741}" > "$OUT/$variant.qemu.log" 2>&1
    init_esp="$(python3 -c 'import json,sys; f=open(sys.argv[1]); next(f); print(json.loads(next(f))["esp"])' "$OUT/$variant.qemu.vtrace")"
    for mode in cycle cycle-func; do
        timeout 15s "$TB" "--$mode" --l1-axi --image "$OUT/$variant.flat" \
            --load 0x08048000 --entry 0x08048000 --init-esp "$init_esp" \
            --out "$OUT/$variant.$mode.vtrace" --max-insn 9000 \
            --max-cycles 200000 --quiesce 1000 > "$OUT/$variant.$mode.log" 2>&1 || {
                tail -50 "$OUT/$variant.$mode.log"; exit 1;
            }
    done
    timeout 15s "$CONTROL" --cycle --l1-axi --image "$OUT/$variant.flat" \
        --load 0x08048000 --entry 0x08048000 --init-esp "$init_esp" \
        --out "$OUT/$variant.control.vtrace" --max-insn 9000 \
        --max-cycles 200000 --quiesce 1000 > "$OUT/$variant.control.log" 2>&1 || {
            tail -50 "$OUT/$variant.control.log"; exit 1;
        }
done
python3 - "$OUT" <<'PY'
import json
from pathlib import Path
import sys

out = Path(sys.argv[1])
keys = ('eax', 'ebx', 'ecx', 'edx', 'esi', 'edi', 'esp', 'ebp',
        'eflags', 'cs', 'ss', 'ds', 'es', 'fs', 'gs')
for variant in ('add_bank', 'add_alias', 'add_crossline',
                'cmp_bank', 'cmp_alias', 'cmp_crossline',
                'uadd_bank', 'uadd_alias', 'uadd_crossline',
                'ucmp_bank', 'back2back', 'alu_back2back'):
    symbols = {parts[2]: int(parts[0], 16)
               for line in (out / f'{variant}.sym').read_text().splitlines()
               if len(parts := line.split()) == 3}
    def rows(mode):
        return [row for line in (out / f'{variant}.{mode}.vtrace').read_text().splitlines()
                if 'pc' in (row := json.loads(line))]
    gold, cycle, state, control = [rows(m) for m in ('qemu', 'cycle', 'cycle-func', 'control')]
    for trace in (cycle, state, control):
        assert len(trace) == len(gold) + 1, (variant, len(trace), len(gold))
        assert int(trace[-1]['pc'], 0) == symbols['exit_syscall'], variant
        trace.pop()
        assert [r['pc'] for r in trace] == [r['pc'] for r in gold], variant
    for i, expected in enumerate(gold):
        if i + 1 < len(gold) and cycle[i]['cyc'] == cycle[i+1]['cyc']:
            continue  # U's intermediate state is not a separate architectural boundary
        for key in keys:
            assert expected[key] == state[i][key], (variant, i, key, expected[key], state[i][key])
    first = [i for i, r in enumerate(cycle) if int(r['pc'], 0) == symbols['first_load']]
    second = [i for i, r in enumerate(cycle) if int(r['pc'], 0) == symbols['second_alu']]
    starts = [i for i, r in enumerate(cycle) if int(r['pc'], 0) == symbols['loop_body']]
    assert len(first) == len(second) == len(starts) == 1000, variant
    pairs = sum(cycle[i]['cyc'] == cycle[j]['cyc'] for i, j in zip(first[100:], second[100:]))
    clocks = cycle[starts[-1]]['cyc'] - cycle[starts[100]]['cyc']
    baseline = control[starts[-1]]['cyc'] - control[starts[100]]['cyc']
    if variant.endswith('_bank') or variant.endswith('back2back'):
        assert pairs == 900 and clocks <= baseline, (variant, pairs, clocks, baseline)
        if variant.startswith('u') or variant == 'alu_back2back':
            assert clocks < baseline, (variant, pairs, clocks, baseline)
    else:
        assert pairs == 0 and clocks <= baseline, (variant, pairs, clocks, baseline)
    print(f'{variant}: QEMU-equivalent, paired={pairs}/900, candidate={clocks}, control={baseline} clocks')
    if variant.endswith('back2back'):
        third = [i for i, r in enumerate(cycle) if int(r['pc'], 0) == symbols['third_load']]
        fourth = [i for i, r in enumerate(cycle) if int(r['pc'], 0) == symbols['fourth_alu']]
        assert len(third) == len(fourth) == 1000
        second_pairs = sum(cycle[i]['cyc'] == cycle[j]['cyc']
                           for i, j in zip(third[100:], fourth[100:]))
        first_to_second = {cycle[j]['cyc'] - cycle[i]['cyc']
                           for i, j in zip(first[100:], third[100:])}
        assert second_pairs == 900, second_pairs
        assert first_to_second == {2}, first_to_second
        print(f'{variant}: second pairs={second_pairs}/900, first-to-second gaps={sorted(first_to_second)}')
print('DUAL-READ-ALU-CORE-GATE-OK (directed, not gameplay)')
PY
printf 'Artifacts: %s\n' "$OUT"
