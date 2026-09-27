#!/usr/bin/env bash
# Resume only a verified same-binary v3 bundle; preserve the source and disk pair.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
: "${RESUME_BUNDLE:?Supply a verified native checkpoint bundle}"
: "${OUTDIR:?Supply a new output directory}"
: "${SAVE_CYCLE:?Supply the absolute final cycle}"
save_cycle="$SAVE_CYCLE"
run_timeout="${RUN_TIMEOUT:-10800}"
[[ "$save_cycle" =~ ^[0-9]{1,12}$ && "$run_timeout" =~ ^[0-9]{1,6}$ ]] || exit 2
(( 10#$save_cycle > 0 && 10#$run_timeout > 0 )) || exit 2
save_cycle=$((10#$save_cycle))
run_timeout=$((10#$run_timeout))
SOURCE="$(realpath "$RESUME_BUNDLE")"
# stage_bundle refuses existing destinations/symlink members and verifies every
# copied byte. Never substitute a newly built executable for the bundled model.
python3 "$ROOT/tools/checkpoint_bundle.py" "$SOURCE" --stage "$OUTDIR"
OUT="$(realpath "$OUTDIR")"
cd "$OUT"
mv gameplay.snap initial.snap
mv gameplay.sha256 source.sha256
sha256sum ao486sim_ven rom/boot0.rom rom/boot1.rom initial.snap > inputs.sha256
printf 'cold_reset=0\nsnapshot_version=3\nrate=45000000\nrate_rtc=45000000\nrate_vga=90000000\nrtc_epoch=1789257600\nfpga_ddr=2\nsave_cycle=%s\nrun_timeout=%s\n' \
    "$save_cycle" "$run_timeout" > settings.txt
cd "$ROOT/ao486-sim"
AO486_BIOS_DIR="$OUT/rom" AO486_RTC_EPOCH=1789257600 FPGA_DDR=2 \
timeout "$run_timeout" "$OUT/ao486sim_ven" --ide "$OUT/guest.vhd" \
    --rate 45000000 --rate-rtc 45000000 --rate-vga 90000000 \
    --mem 32 --cycles "$((save_cycle + 5000000))" --snapshot-v3 \
    --restore "$OUT/initial.snap" --save-at "$save_cycle" --save-stop \
    --save-file "$OUT/gameplay.snap" --ven-perf-every 50000000 \
    --vgatext-every 50000000 --fb-every 50000000 --fb-out "$OUT/frame" \
    > "$OUT/capture.log" 2>&1
cd "$OUT"
test -s gameplay.snap
# Reject accidentally requesting a past checkpoint. Native restore validates
# the clock/DDR/ATA ABI; the log supplies its actual absolute start/stop cycle.
python3 - "$save_cycle" <<'PY'
from pathlib import Path
import re, sys
log = Path('capture.log').read_text()
starts = re.findall(r'>>> STATE LOADED .* @cyc=(\d+) ', log)
ends = re.findall(r'>>> STATE SAVED .* @cyc=(\d+) ', log)
if len(starts) != 1 or len(ends) != 1:
    raise SystemExit('RESUME-CAPTURE-FAIL: expected one restore and one save')
start, end, target = int(starts[0]), int(ends[0]), int(sys.argv[1])
if not start < target <= end < target + 5000000:
    raise SystemExit('RESUME-CAPTURE-FAIL: invalid start/target/end cycles')
print(f'RESUME-CYCLES-OK start={start} end={end}')
PY
sha256sum -c inputs.sha256
python3 "$ROOT/tools/checkpoint_bundle.py" "$SOURCE"
sha256sum ao486sim_ven rom/boot0.rom rom/boot1.rom gameplay.snap guest.vhd > gameplay.sha256
python3 "$ROOT/tools/checkpoint_bundle.py" "$OUT"
echo 'RESUME-CAPTURE-COMPLETE (same binary; visual gameplay still requires verification)'
