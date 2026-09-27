#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if ! "$ROOT/tools/build_scope.sh" --is-active; then
    exec "$ROOT/tools/build_scope.sh" -- bash "$0" "$@"
fi
: "${MODEL_DIR:?Supply the preserved full-PC generated model directory}"
model="$(realpath "$MODEL_DIR")"
verilator_inc="$(verilator -V | sed -n 's/^ *VERILATOR_ROOT *= *//p' | head -n 1)/include"
test -f "$verilator_inc/verilated.h"
out="$(mktemp -d /tmp/ventium-rtc-rate.XXXXXX)"
echo "Artifacts: $out"
g++ -std=c++17 -Wall -Wextra -Werror "$ROOT/ao486-sim/ven/test_rtc_rate.cpp" -o "$out/test_rtc_rate"
"$out/test_rtc_rate"
g++ -std=c++17 -fsyntax-only -I"$model" -I"$verilator_inc" -I"$verilator_inc/vltstd" \
    -I"$ROOT/ao486-sim/ps" "$ROOT/ao486-sim/ven/sim_ven.cpp"
echo RTC-RATE-HARNESS-SYNTAX-OK
