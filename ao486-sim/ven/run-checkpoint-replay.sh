#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Same-binary native-state replay, optional private disk copies, no guest edits.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
: "${SIM_BIN:?Supply a full-PC binary with the requested snapshot version}"
: "${AO486_BIOS_DIR:?Supply the BIOS ROM directory used by the candidate}"
SIM="$(realpath "$SIM_BIN")"
DISK="${DISK_IMAGE:+$(realpath "$DISK_IMAGE")}"
OUT="${OUTDIR:-$(mktemp -d /tmp/ventium-checkpoint-replay.XXXXXX)}"
mkdir -p "$OUT"
OUT="$(realpath "$OUT")"
cd "$ROOT/ao486-sim"
export AO486_RTC_EPOCH=1789257600
save_cycle="${SAVE_CYCLE:-2000000}"
end_cycle="${END_CYCLE:-3000000}"
[[ "$save_cycle" =~ ^[0-9]+$ && "$end_cycle" =~ ^[0-9]+$ ]] || exit 2
(( save_cycle > 0 && end_cycle > save_cycle )) || exit 2
snapshot_version="${SNAPSHOT_VERSION:-3}"
[[ "$snapshot_version" == 2 || "$snapshot_version" == 3 ]] || exit 2
# Match the cold/resume capture timebases explicitly. The simulator's legacy
# RTC default is not the current 45 MHz capture rate; a cold replay comparison
# at that default would certify a different machine configuration.
common=(--rate 45000000 --rate-rtc 45000000 --rate-vga 90000000
        --mem 32 "--snapshot-v$snapshot_version" --save-stop --cycles "$((end_cycle + 5000000))")
# Optional same-executable starting checkpoint lets the three-way comparison
# exercise gameplay without repeating startup. DISK_IMAGE must be its stopped
# disk partner; verify the enclosing bundle before invoking this gate.
initial_restore=()
if [[ -n "${INITIAL_SNAPSHOT:-}" ]]; then
    initial_restore=(--restore "$(realpath "$INITIAL_SNAPSHOT")")
fi
# Do not overwrite prior checkpoints: a rerun needs a fresh output directory.
for name in uninterrupted checkpoint replay; do
    [[ ! -e "$OUT/$name.snap" ]] || { echo "Refusing to overwrite $OUT/$name.snap"; exit 2; }
done
disk_a=(); disk_b=(); disk_c=()
if [[ -n "$DISK" ]]; then
    for name in uninterrupted checkpoint replay; do
        # A fixed basename keeps guest-visible ATA IDENTIFY strings identical.
        mkdir "$OUT/disk-$name"
    done
    cp --reflink=auto --sparse=always "$DISK" "$OUT/disk-uninterrupted/guest.vhd"
    cp --reflink=auto --sparse=always "$DISK" "$OUT/disk-checkpoint/guest.vhd"
    # IDE requires writable private copies even when the archived input is 0444.
    chmod u+w -- "$OUT/disk-uninterrupted/guest.vhd" "$OUT/disk-checkpoint/guest.vhd"
    disk_a=(--ide "$OUT/disk-uninterrupted/guest.vhd")
    disk_b=(--ide "$OUT/disk-checkpoint/guest.vhd")
    disk_c=(--ide "$OUT/disk-replay/guest.vhd")
fi
FPGA_DDR=2 timeout "${RUN_TIMEOUT:-120}" "$SIM" "${common[@]}" "${disk_a[@]}" "${initial_restore[@]}" --save-at "$end_cycle" \
    --save-file "$OUT/uninterrupted.snap" > "$OUT/uninterrupted.log" 2>&1
FPGA_DDR=2 timeout "${RUN_TIMEOUT:-120}" "$SIM" "${common[@]}" "${disk_b[@]}" "${initial_restore[@]}" --save-at "$save_cycle" \
    --save-file "$OUT/checkpoint.snap" > "$OUT/checkpoint.log" 2>&1
if [[ -n "$DISK" ]]; then
    # The checkpoint process has exited and flushed its disk; freeze that state
    # before allowing the replay to make any writes of its own.
    cp --reflink=auto --sparse=always "$OUT/disk-checkpoint/guest.vhd" "$OUT/disk-replay/guest.vhd"
    chmod u+w -- "$OUT/disk-replay/guest.vhd"
fi
FPGA_DDR=2 timeout "${RUN_TIMEOUT:-120}" "$SIM" "${common[@]}" "${disk_c[@]}" --restore "$OUT/checkpoint.snap" \
    --save-at "$end_cycle" --save-file "$OUT/replay.snap" > "$OUT/replay.log" 2>&1
cmp "$OUT/uninterrupted.snap" "$OUT/replay.snap"
if [[ -n "$DISK" ]]; then
    cmp "$OUT/disk-uninterrupted/guest.vhd" "$OUT/disk-replay/guest.vhd"
    echo "CHECKPOINT-DISK-REPLAY-OK (same executable, full state and final disk identical)"
else
    echo "CHECKPOINT-REPLAY-OK (same executable, BIOS only, full serialized state identical)"
fi
echo "Artifacts: $OUT"
