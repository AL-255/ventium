#!/usr/bin/env bash
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# tools/pipeviz/build.sh — verilate ventium_top with --public-flat-rw (so the
# pipeline visualizer's C++ bridge can read every internal core/cache/TLB/FPU
# signal via the generated ___024root struct) and link the bridge into the
# shared library libventium_viz.so consumed by the PySide6 GUI (pipeviz/).
#
# Reuses the production BFM memory (verif/tb/memmodel.cpp). Self-contained: never
# touches rtl/ or the verification build dirs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OBJ="$HERE/obj_dir"
OBJO="$HERE/build_o"
RTL_F="$ROOT/rtl/ventium.f"
TB="$ROOT/verif/tb"
VERILATOR="${VERILATOR:-verilator}"
JOBS="$(nproc 2>/dev/null || echo 4)"

echo "[pipeviz] verilator: $($VERILATOR --version 2>&1 | head -1)"

# ---- locate the Verilator runtime include dir ------------------------------
VINC=""
if VR="$($VERILATOR --getenv VERILATOR_ROOT 2>/dev/null)" && [ -n "$VR" ] && [ -d "$VR/include" ]; then
  VINC="$VR/include"
else
  for c in /usr/share/verilator/include /usr/local/share/verilator/include \
           "$(dirname "$(command -v "$VERILATOR")")/../share/verilator/include"; do
    [ -d "$c" ] && { VINC="$c"; break; }
  done
fi
[ -n "$VINC" ] && [ -f "$VINC/verilated.cpp" ] || {
  echo "[pipeviz] ERROR: cannot find the Verilator include dir (verilated.cpp)." >&2
  echo "          Set VERILATOR_ROOT or install verilator's runtime sources." >&2
  exit 1
}
echo "[pipeviz] verilator runtime include: $VINC"

# ---- 1. generate the verilated C++ (public-flat-rw, no exe) -----------------
echo "[pipeviz] verilating ventium_top (--public-flat-rw) ..."
rm -rf "$OBJ"
"$VERILATOR" --cc --public-flat-rw \
  -sv --top-module ventium_top \
  -Wall -Wno-UNUSED -Wno-fatal -Wno-DECLFILENAME -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-LATCH \
  -Mdir "$OBJ" \
  -F "$RTL_F"

# ---- 2. compile everything -fPIC (parallel) ---------------------------------
echo "[pipeviz] compiling bridge + verilated model (-fPIC, -j$JOBS) ..."
rm -rf "$OBJO"; mkdir -p "$OBJO"
INCS=(-I"$OBJ" -I"$VINC" -I"$VINC/vltstd" -I"$TB" -I"$HERE")
CXXFLAGS=(-std=c++17 -O1 -fPIC -fno-strict-aliasing -Wno-attributes "${INCS[@]}")

# the sources: generated model + verilator runtime + our bridge + the BFM memory
SRCS=( "$OBJ"/*.cpp
       "$VINC/verilated.cpp"
       "$VINC/verilated_threads.cpp"
       "$VINC/verilated_dpi.cpp"
       "$HERE/ventium_viz.cpp"
       "$TB/memmodel.cpp" )

# robust parallel compile: one object per source, throttled to $JOBS workers.
fail=0
for src in "${SRCS[@]}"; do
  o="$OBJO/$(printf '%s' "$src" | md5sum | cut -c1-16)_$(basename "$src").o"
  ( g++ "${CXXFLAGS[@]}" -c "$src" -o "$o" || { echo "[pipeviz] COMPILE FAILED: $src" >&2; exit 1; } ) &
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || fail=1; done
done
wait || fail=1
[ "$fail" -eq 0 ] || { echo "[pipeviz] ERROR: one or more compiles failed." >&2; exit 1; }

# ---- 3. link the shared library --------------------------------------------
echo "[pipeviz] linking libventium_viz.so ..."
g++ -shared -fPIC "$OBJO"/*.o -o "$HERE/libventium_viz.so" -lpthread -latomic 2>/dev/null \
  || g++ -shared -fPIC "$OBJO"/*.o -o "$HERE/libventium_viz.so" -lpthread

echo "[pipeviz] OK -> $HERE/libventium_viz.so"
ls -la "$HERE/libventium_viz.so"
