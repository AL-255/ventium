#!/usr/bin/env bash
# Cold-reset capture for changed RTL; native snapshots remain same-build only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
: "${SIM_BIN:?Supply the experimental full-PC executable}"
: "${DISK_IMAGE:?Supply the immutable cold-boot disk image}"
: "${AO486_BIOS_DIR:?Supply the BIOS ROM directory}"
SIM="$(realpath "$SIM_BIN")"
DISK="$(realpath "$DISK_IMAGE")"
ROM="$(realpath "$AO486_BIOS_DIR")"
save_cycle="${SAVE_CYCLE:-1300000000}"
run_timeout="${RUN_TIMEOUT:-10800}"
[[ "$save_cycle" =~ ^[0-9]{1,12}$ && "$run_timeout" =~ ^[0-9]{1,6}$ ]] || exit 2
(( 10#$save_cycle > 0 && 10#$run_timeout > 0 )) || exit 2
save_cycle=$((10#$save_cycle))
run_timeout=$((10#$run_timeout))
[[ -x "$SIM" && -f "$DISK" && -f "$ROM/boot0.rom" && -f "$ROM/boot1.rom" ]] || exit 2
if [[ -n "${OUTDIR:-}" ]]; then
    # No overwrites or reuse of a disk modified by an earlier run.
    mkdir -- "$OUTDIR"
    OUT="$(realpath "$OUTDIR")"
else
    OUT="$(mktemp -d /tmp/ventium-cold-gameplay.XXXXXX)"
fi
echo "Artifacts: $OUT"
mkdir "$OUT/rom"
cp -- "$SIM" "$OUT/ao486sim_ven"
cp -- "$ROM/boot0.rom" "$ROM/boot1.rom" "$OUT/rom/"
cp --reflink=auto --sparse=always -- "$DISK" "$OUT/boot.vhd"
cd "$OUT"
sha256sum ao486sim_ven rom/boot0.rom rom/boot1.rom boot.vhd > inputs.sha256
cp --reflink=auto --sparse=always boot.vhd guest.vhd
# Immutable archived inputs may be mode 0444. IDE opens only this new private
# copy read/write; never change the source disk or the boot-input copy's mode.
chmod u+w -- guest.vhd
printf 'cold_reset=1\nsnapshot_version=3\nrate=45000000\nrate_rtc=45000000\nrate_vga=90000000\nrtc_epoch=1789257600\nfpga_ddr=2\nsave_cycle=%s\nrun_timeout=%s\n' \
    "$save_cycle" "$run_timeout" > settings.txt
cd "$ROOT/ao486-sim"
AO486_BIOS_DIR="$OUT/rom" AO486_RTC_EPOCH=1789257600 FPGA_DDR=2 \
timeout "$run_timeout" "$OUT/ao486sim_ven" --ide "$OUT/guest.vhd" \
    --rate 45000000 --rate-rtc 45000000 --rate-vga 90000000 \
    --mem 32 --cycles "$((save_cycle + 5000000))" \
    --snapshot-v3 --save-at "$save_cycle" --save-stop \
    --save-file "$OUT/gameplay.snap" --ven-perf-every 50000000 \
    --vgatext-every 50000000 --fb-every 50000000 --fb-out "$OUT/frame" \
    > "$OUT/capture.log" 2>&1
cd "$OUT"
test -s gameplay.snap
sha256sum -c inputs.sha256
sha256sum ao486sim_ven rom/boot0.rom rom/boot1.rom gameplay.snap guest.vhd > gameplay.sha256
python3 "$ROOT/tools/checkpoint_bundle.py" "$OUT"
echo 'CAPTURE-COMPLETE (visual gameplay and same-build replay still require verification)'
