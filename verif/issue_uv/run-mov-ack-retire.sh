#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Prebuilt whole-core only. Global deadline <10min; no Verilator/full-system run.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${MOV_ACK_DEADLINE_ACTIVE:-0}" != 1 ]]; then
  exec timeout 540s env MOV_ACK_DEADLINE_ACTIVE=1 bash "$0" "$@"
fi
: "${TB_BIN:?Supply the frozen MOV-ACK candidate tb_ventium}"
TB="$(realpath "$TB_BIN")"
QEMU="$ROOT/ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386"
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-mov-ack.XXXXXX)}"
mkdir -p "$OUT"
ulimit -v 1048576
cases=()
for width in 8 16 32; do
  for lane in {0..7}; do
    for offset in 0 1 2 3 31 4095; do
      cases+=("${width}_${lane}_${offset}_0_3735928559")
    done
  done
  cases+=("${width}_0_0_0_0" "${width}_0_0_1_2147483648")
done
cases+=("16_0_0_2_0" "16_0_0_3_4294967295")
[[ -z "${CASE_ONLY:-}" ]] || cases=("$CASE_ONLY")
jobs="${MOV_ACK_JOBS:-1}"
[[ "$jobs" =~ ^([1-9]|1[0-9]|2[0-4])$ ]] || {
  echo 'MOV_ACK_JOBS must be between 1 and 24';exit 2;
}
if (( jobs>1 )) && [[ -z "${CASE_ONLY:-}" ]]; then
  # One enclosing capped scope, not one independently guarded scope per case.
  # 24 workers fit the existing 128-task profile (each QEMU phase has its shell,
  # timeout, Python producer and two QEMU tasks). Ports are unique per batch.
  if ! "$ROOT/tools/build_scope.sh" --is-active; then
    echo 'Parallel MOV cases require one enclosing tools/build_scope.sh profile';exit 2;
  fi
  pids=();names=();index=0
  wait_batch() {
    local i
    for i in "${!pids[@]}"; do
      if ! wait "${pids[$i]}"; then
        printf 'MOV case failed: %s\n' "${names[$i]}"
        tail -n 40 "$OUT/${names[$i]}.gate.log"
        return 1
      fi
    done
    printf 'MOV-ACK progress: %s/%s cases checked\n' "$index" "${#cases[@]}"
    pids=();names=()
  }
  for case_id in "${cases[@]}"; do
    OUTDIR="$OUT" CASE_ONLY="$case_id" MOV_ACK_JOBS=1 \
      PORT="$(( ${PORT:-41431} + index%jobs ))" \
      bash "$0" > "$OUT/$case_id.gate.log" 2>&1 &
    pids+=("$!");names+=("$case_id");index=$((index+1))
    if (( ${#pids[@]}==jobs )); then wait_batch;fi
  done
  if (( ${#pids[@]}>0 )); then wait_batch;fi
  printf 'MOV-ACK-RETIRE-OK cases=%s jobs=%s\nArtifacts: %s\n' "${#cases[@]}" "$jobs" "$OUT"
  exit 0
fi
memory_args=()
[[ "${RAW_MEMORY:-1}" == 1 ]] || memory_args=(--l1-axi)
for case_id in "${cases[@]}"; do
  [[ "$case_id" =~ ^(8|16|32)_[0-7]_(0|1|2|3|31|4095)_[0-3]_[0-9]{1,10}$ ]] || {
    echo 'Invalid CASE_ONLY';exit 2;
  }
  IFS=_ read -r width lane offset mode value <<< "$case_id"
  as --32 --defsym WIDTH="$width" --defsym LANE="$lane" \
    --defsym DATA_OFFSET="$offset" --defsym MODE="$mode" --defsym VALUE="$value" \
    "$ROOT/verif/issue_uv/t_mov_ack_retire.s" -o "$OUT/$case_id.o"
  ld -m elf_i386 -Ttext 0x08048000 "$OUT/$case_id.o" -o "$OUT/$case_id.elf"
  nm -n "$OUT/$case_id.elf" > "$OUT/$case_id.sym"
  python3 "$ROOT/verif/tests/elf2flat.py" "$OUT/$case_id.elf" \
    --out "$OUT/$case_id.flat" --base 0x08048000 > "$OUT/$case_id.flat.log"
  QEMU_RESERVED_VA=256M QEMU_CPU=pentium timeout 15s \
    python3 "$ROOT/verif/qemu-trace/gen_trace.py" --qemu "$QEMU" \
    --elf "$OUT/$case_id.elf" --out "$OUT/$case_id.qemu.vtrace" \
    --max-insn 120 --port "${PORT:-41431}" > "$OUT/$case_id.qemu.log" 2>&1
  init_esp="$(python3 -c 'import json,sys; f=open(sys.argv[1]); next(f); print(json.loads(next(f))["esp"])' "$OUT/$case_id.qemu.vtrace")"
  for run_mode in cycle cycle-func; do
    timeout 15s "$TB" "--$run_mode" "${memory_args[@]}" \
      --image "$OUT/$case_id.flat" --load 0x08048000 --entry 0x08048000 \
      --init-esp "$init_esp" --out "$OUT/$case_id.$run_mode.vtrace" \
      --max-insn 120 --max-cycles 200000 --quiesce 1000 \
      > "$OUT/$case_id.$run_mode.log" 2>&1
  done
done
python3 - "$OUT" "${cases[@]}" <<'PY'
import json,os,pathlib,sys
out=pathlib.Path(sys.argv[1])
keys=('eax','ebx','ecx','edx','esi','edi','esp','ebp','eflags','cs','ss','ds','es','fs','gs')
for case in sys.argv[2:]:
    width,lane,offset,mode,value=map(int,case.split('_'))
    symbols={p[2]:int(p[0],16) for line in (out/f'{case}.sym').read_text().splitlines()
             if len(p:=line.split())==3}
    def rows(kind):
        return [r for line in (out/f'{case}.{kind}.vtrace').read_text().splitlines()
                if 'pc' in (r:=json.loads(line))]
    gold,cycle,state=[rows(k) for k in ('qemu','cycle','cycle-func')]
    for trace in (cycle,state):
        assert len(trace)==len(gold)+1,(case,'incomplete program',len(trace),len(gold))
        assert int(trace[-1]['pc'],0)==symbols['exit_syscall']
        trace.pop()
    assert [r['pc'] for r in gold]==[r['pc'] for r in cycle]==[r['pc'] for r in state],case
    for i in range(len(gold)):
        if i+1<len(gold) and cycle[i]['cyc']==cycle[i+1]['cyc']:
            continue
        for key in keys:
            assert gold[i][key]==state[i][key],(case,i,key,gold[i],state[i])
    indices=[i for i,r in enumerate(cycle) if int(r['pc'],0)==symbols['tested_op']]
    assert len(indices)==8,(case,len(indices))
    gaps=[cycle[i]['cyc']-cycle[i-1]['cyc'] for i in indices[2:]]
    # Word MOV retains 66 D1 + one EX; memory CMP/TEST retain 66 + two EX.
    floor=3 if mode in (2,3) else 2
    assert min(gaps)>=floor,(case,'period execution/prefix floor',gaps,floor)
    if width==16 and mode==0 and offset in (0,2) and os.environ.get('RAW_MEMORY','1')=='1':
        assert max(gaps)==2,(case,'plain warm word MOV still has an extra EX edge',gaps)
    if mode==1:
        assert min(gaps)>=3,(case,'multiple-prefix conservative path was bypassed',gaps)
    print(f'{case}: all QEMU states checked; warm source-retire clocks={min(gaps)}..{max(gaps)}')
print(f'MOV-ACK-RETIRE-OK cases={len(sys.argv)-2}')
PY
printf 'Artifacts: %s\n' "$OUT"
