#!/usr/bin/env bash
# Fixed-work four-code-page I-TLB conflict A/B; bounded below ten minutes.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 CONTROL_TB CANDIDATE_TB [ITERATIONS=200]" >&2
  exit 2
fi
control="$1"
candidate="$2"
iterations="${3:-200}"
[[ -x "$control" && -x "$candidate" ]] || { echo "both TB binaries must be executable" >&2; exit 2; }
[[ "$iterations" =~ ^[0-9]+$ ]] && (( iterations >= 102 && iterations <= 1000 )) || {
  echo "ITERATIONS must be 102..1000" >&2; exit 2
}
SECONDS=0
out="$(mktemp -d "${P54_TLB_OUTBASE:-/tmp}/ventium-p54-itlb-assoc-core.XXXXXX")"
echo "Artifacts: $out"
run() {
  local remaining=$((540 - SECONDS))
  (( remaining > 0 )) || { echo "microbenchmark nine-minute budget expired" >&2; exit 1; }
  timeout --signal=TERM --kill-after=10s "$remaining" "$@"
}
run as --32 --defsym "ITERATIONS=$iterations" \
  "$root/verif/bench/p54_itlb_assoc_bios.S" -o "$out/test.o"
run ld -m elf_i386 -T "$root/verif/sys/tests/pmode/pmode.ld" \
  -o "$out/test.elf" "$out/test.o"
run objcopy -O binary "$out/test.elf" "$out/test.bin"
run truncate -s 65536 "$out/test.bin"
sha256sum "$control" "$candidate" "$out/test.bin" > "$out/inputs.sha256"
max_insn=$((iterations * 16 + 1600))
max_cycles=$((iterations * 500 + 50000))
qemu="$root/ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
run python3 "$root/verif/qemu-trace/gen_trace.py" --qemu "$qemu" \
  --system --image "$out/test.bin" --image-mode bios \
  --out "$out/qemu.vtrace" --max-insn "$max_insn" --port 42561 \
  > "$out/qemu.log" 2>&1
rg -q 'guest exited, code=0' "$out/qemu.log" || {
  echo "pinned QEMU did not report the self-check pass exit" >&2
  exit 1
}
for name in control candidate; do
  if [[ "$name" == control ]]; then binary="$control"; else binary="$candidate"; fi
  run "$binary" --cycle --system --l1-axi --image "$out/test.bin" \
    --out "$out/$name.vtrace" --max-insn "$max_insn" \
    --max-cycles "$max_cycles" --quiesce 400 > "$out/$name.log" 2>&1
done
run "$candidate" --system --l1-axi --image "$out/test.bin" \
  --out "$out/candidate.func.vtrace" --max-insn "$max_insn" \
  --max-cycles "$max_cycles" --quiesce 400 > "$out/candidate.func.log" 2>&1
run python3 "$root/verif/diff/compare_stream.py" \
  "$out/control.vtrace" "$out/candidate.vtrace" --sys \
  > "$out/architectural-ab.log"
run python3 "$root/verif/diff/compare.py" --mode func --all \
  "$out/qemu.vtrace" "$out/candidate.func.vtrace" \
  > "$out/qemu-diff.log"
for name in control candidate; do
  jq -r 'select(.pc=="0x00010000") | "\(.cyc) \(.n)"' \
    "$out/$name.vtrace" | awk -v name="$name" -v expected="$iterations" '
      NR==101 {first_c=$1; first_n=$2}
      {last_c=$1; last_n=$2}
      END {
        if (NR != expected || last_c <= first_c || last_n <= first_n) exit 1;
        printf "%s starts=%d warm_instructions=%d warm_clocks=%d cycles_per_iteration=%.6f ipc=%.6f\n",
          name, NR, last_n-first_n, last_c-first_c,
          (last_c-first_c)/(NR-101), (last_n-first_n)/(last_c-first_c);
      }'
done | tee "$out/results.txt"
echo "P54-ITLB-ASSOC-CORE-MICRO-OK: fixed work, QEMU architectural diff, A/B equality"
