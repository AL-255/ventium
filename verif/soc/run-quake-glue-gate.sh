#!/usr/bin/env bash
# verif/soc/run-quake-glue-gate.sh — unit gate for the F4 board Quake glue
# (sw/ps/ven_soc_app/ven_quake.* + mem_carveout.cpp + the ported verif/tb syscall
# emulator + image loader). Builds the host harness test_quake_glue.c against a
# malloc'd stand-in carveout, stages the real captured Quake image, and drives a
# few int-0x80s the way the board service loop does. Asserts GLUE-OK. Run from
# repo root. (The on-board half — the RTL 0x40-0x6C window + the real core — is
# covered by run-soc-axil-gate.sh's +VEN_PS_PROXY phase.)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/sw/ps/ven_soc_app"
TB="$ROOT/verif/tb"
IMG="$ROOT/build/quake-fb/image.json"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

[[ -f "$IMG" ]] || { echo "QUAKE-GLUE-SKIP (no $IMG; run verif/bench/run-quake-fb.sh first)"; exit 0; }

CXX="${CXX:-g++}"; CC="${CC:-gcc}"
INC="-I$APP -I$TB"
$CXX -O2 -std=c++17 $INC -c "$APP/ven_quake.cpp"     -o "$OBJ/ven_quake.o"
$CXX -O2 -std=c++17 $INC -c "$APP/mem_carveout.cpp"  -o "$OBJ/mem_carveout.o"
$CXX -O2 -std=c++17 $INC -c "$TB/syscall_emu.cpp"    -o "$OBJ/syscall_emu.o"
$CXX -O2 -std=c++17 $INC -c "$TB/quake_image.cpp"    -o "$OBJ/quake_image.o"
$CC  -O2 -std=c11   -I"$APP" -c "$APP/ven_systrace.c"    -o "$OBJ/ven_systrace.o"
$CC  -O2 -std=c11   -I"$APP" -c "$APP/test_quake_glue.c" -o "$OBJ/test.o"
$CXX -o "$OBJ/test_quake_glue" "$OBJ"/*.o

OUT="$("$OBJ/test_quake_glue" "$IMG" 2>/dev/null)"
echo "$OUT"
grep -q "GLUE-OK" <<<"$OUT" || { echo "QUAKE-GLUE-FAIL"; exit 1; }
echo "== ven_soc_app Quake glue gate PASS =="
